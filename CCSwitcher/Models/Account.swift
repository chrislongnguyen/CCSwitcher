import Foundation

// MARK: - Provider Type (extensible for Gemini, Codex, etc.)

enum AIProviderType: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case gemini = "Gemini"
    case codex = "Codex"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .claudeCode: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var configDirectory: String {
        switch self {
        case .claudeCode: return "~/.claude"
        case .gemini: return "~/.gemini"
        case .codex: return "~/.codex"
        }
    }
}

// MARK: - Account Model

struct Account: Identifiable, Codable, Hashable {
    let id: UUID
    var email: String
    var displayName: String
    var provider: AIProviderType
    var orgName: String?
    var subscriptionType: String?
    var isActive: Bool
    var lastUsed: Date?
    var customLabel: String?

    /// Subscription type with first letter capitalized (e.g., "max" → "Max").
    var displaySubscriptionType: String? {
        subscriptionType?.prefix(1).uppercased().appending(subscriptionType?.dropFirst() ?? "")
    }

    var obfuscatedEmail: String {
        // This field IS an address — mask structurally, no detection step, so
        // non-ASCII/quoted/punycode/literal forms can never slip through.
        return email.maskedAsEmailAddress()
    }

    var obfuscatedDisplayName: String {
        // displayName is orgName ?? email: when it IS the email, mask it
        // structurally like the email field; otherwise treat it as free text
        // and only mask what the conservative detector recognizes.
        if displayName == email {
            return email.maskedAsEmailAddress()
        }
        return displayName.obfuscatedEmail()
    }

    /// Returns customLabel if set and non-empty, otherwise falls back to obfuscatedDisplayName.
    var effectiveDisplayName: String {
        if let label = customLabel, !label.isEmpty {
            return label
        }
        return obfuscatedDisplayName
    }

    /// Returns the email, optionally obfuscated.
    func displayEmail(obfuscated: Bool) -> String {
        obfuscated ? obfuscatedEmail : email
    }

    /// Returns the effective display name, optionally obfuscating the fallback.
    func effectiveDisplayName(obfuscated: Bool) -> String {
        if let label = customLabel, !label.isEmpty {
            return label
        }
        return obfuscated ? obfuscatedDisplayName : displayName
    }

    init(
        id: UUID = UUID(),
        email: String,
        displayName: String,
        provider: AIProviderType = .claudeCode,
        orgName: String? = nil,
        subscriptionType: String? = nil,
        isActive: Bool = false,
        lastUsed: Date? = nil,
        customLabel: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.provider = provider
        self.orgName = orgName
        self.subscriptionType = subscriptionType
        self.isActive = isActive
        self.lastUsed = lastUsed
        self.customLabel = customLabel
    }
}

// MARK: - Auth Status (from `claude auth status`)

/// Decoded `claude auth status` output.
///
/// The CLI only emits `email`, `orgId`, `orgName` and `subscriptionType` when
/// `authMethod == "claude.ai"` — that is, when the stored claude.ai login is the
/// credential source it actually resolves to. Any higher-precedence source
/// shadows the stored login and the whole identity block is omitted while
/// `loggedIn` stays `true`: an `ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN`
/// environment variable, an `apiKeyHelper`, an OAuth token file, an Anthropic
/// profile in `~/.config/anthropic`, or a third-party provider (Bedrock, Vertex,
/// …). Callers must therefore treat a missing `email` as "identity unavailable",
/// never as "a different account is active".
///
/// Identity is read from `OAuthIdentity` (`~/.claude.json` `oauthAccount`), not from
/// this struct: since Claude Code v2.1.139 `claude auth status` may omit the identity
/// fields entirely.
struct AuthStatus: Codable {
    let loggedIn: Bool
    let authMethod: String?
    let apiProvider: String?
    // Deprecated since Claude Code v2.1.139 — these fields are always nil now.
    // Retained for backward deserialization only.
    let email: String?
    let orgId: String?
    let orgName: String?
    let subscriptionType: String?

    /// True when the CLI reports the identity of the stored claude.ai login,
    /// i.e. when `email` is meaningful.
    var reportsClaudeAiIdentity: Bool {
        authMethod == "claude.ai"
    }

    /// The credential source shadowing the stored claude.ai login, or `nil` when
    /// nothing shadows it. Only meaningful while `loggedIn` is `true`.
    var shadowingAuthMethod: String? {
        reportsClaudeAiIdentity ? nil : (authMethod ?? "unknown")
    }
}

// MARK: - OAuth Identity (from `~/.claude.json` `oauthAccount`)

/// Structured identity read from `~/.claude.json`'s `oauthAccount` field.
/// This is the canonical identity source since `claude auth status` stopped
/// returning email/org/subscription in v2.1.139 (2026-05-11).
struct OAuthIdentity: CustomStringConvertible {
    let emailAddress: String
    let displayName: String?
    let organizationName: String?
    let organizationUuid: String?
    let accountUuid: String?
    let organizationType: String?      // e.g. "claude_team", "claude_business"
    let seatTier: String?              // e.g. "team_tier_1"
    let billingType: String?           // e.g. "stripe_subscription"
    let userRateLimitTier: String?
    let organizationRateLimitTier: String?
    let hasExtraUsageEnabled: Bool
    let accountCreatedAt: String?
    let subscriptionCreatedAt: String?

    /// Prevents accidental PII/credential leakage if the struct is logged as a whole.
    var description: String {
        "OAuthIdentity(email: \(emailAddress), org: \(organizationName ?? "nil"))"
    }

    /// Normalised subscription-type label (e.g. "Team", "Max", "Pro")
    var subscriptionTypeLabel: String? {
        // Prefer seatTier → organizationType → nil
        if let tier = seatTier {
            // "team_tier_1" → "Team"
            let parts = tier.split(separator: "_")
            if let first = parts.first {
                return first.prefix(1).uppercased() + first.dropFirst()
            }
        }
        if let orgType = organizationType {
            // "claude_team" → "Team", "claude_business" → "Business"
            let name = orgType.replacingOccurrences(of: "claude_", with: "")
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return nil
    }
}
