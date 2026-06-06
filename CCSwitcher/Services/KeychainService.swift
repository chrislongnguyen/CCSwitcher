import Foundation
import Security

private let log = FileLog("Keychain")

/// Per-account backup: keychain token + oauthAccount from ~/.claude.json
struct AccountBackup: Codable {
    let token: String
    let oauthAccount: [String: AnyCodable]
}

/// Type-erased Codable wrapper for heterogeneous JSON values.
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a }
        else if let o = try? container.decode([String: AnyCodable].self) { value = o }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        case let a as [AnyCodable]: try container.encode(a)
        case let o as [String: AnyCodable]: try container.encode(o)
        default: throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported type"))
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

/// Manages token + identity storage:
/// - Claude CLI's token: file-primary (live-token.txt), keychain fallback via Security framework.
/// - Claude CLI's identity: read/write oauthAccount in ~/.claude.json.
/// - Our backups: per-account {token, oauthAccount} in ~/.ccswitcher/backups.json (file, no keychain ACL).
final class KeychainService: Sendable {
    static let shared = KeychainService()

    private let claudeService = "Claude Code-credentials"
    private let claudeAccount: String
    private let liveTokenPath: String
    private let backupsFilePath: String
    private let claudeJsonPath: String

    private init() {
        self.claudeAccount = NSUserName()

        let home = NSHomeDirectory()
        let dir = home + "/.ccswitcher"
        self.liveTokenPath = dir + "/live-token.txt"
        self.backupsFilePath = dir + "/backups.json"
        self.claudeJsonPath = home + "/.claude.json"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Migrate old tokens.json → backups.json if needed
        let oldPath = dir + "/tokens.json"
        if FileManager.default.fileExists(atPath: oldPath) && !FileManager.default.fileExists(atPath: backupsFilePath) {
            log.info("init: Migrating tokens.json → backups.json (old format, token-only entries)")
            // Old format was {accountId: tokenString}. We can't migrate without oauthAccount,
            // so just delete the stale file — user will need to re-capture.
            try? FileManager.default.removeItem(atPath: oldPath)
        }

        log.info("init: claudeAccount=\(claudeAccount), backupsFile=\(backupsFilePath)")
    }

    // MARK: - Claude Code Token Operations (file primary, keychain fallback)

    func readClaudeToken() -> String? {
        // Primary: file-based token (no keychain prompt, survives rebuilds)
        if let fileToken = readTokenFromFile() {
            return fileToken
        }
        // Fallback: Security framework keychain (may trigger macOS prompt)
        if let keychainToken = readTokenFromKeychain() {
            return keychainToken
        }
        return nil
    }

    private func readTokenFromFile() -> String? {
        guard FileManager.default.fileExists(atPath: liveTokenPath),
              let token = try? String(contentsOfFile: liveTokenPath, encoding: .utf8) else {
            return nil
        }
        let sanitized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return nil }
        log.info("[readClaudeToken] Found via file, length=\(sanitized.count)")
        return sanitized
    }

    private func readTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeService,
            kSecAttrAccount as String: claudeAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            log.warning("[readClaudeToken] Keychain fallback failed, status=\(status)")
            return nil
        }

        let sanitized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        log.info("[readClaudeToken] Found via keychain, length=\(sanitized.count)")
        _ = saveTokenToFile(sanitized) // seed file so next read skips keychain entirely
        return sanitized
    }

    /// Refresh the local token file (call after `claude auth login` or manual keychain update).
    func refreshTokenFile() -> Bool {
        if let token = readTokenFromKeychain() {
            return saveTokenToFile(token)
        }
        return false
    }

    private func saveTokenToFile(_ token: String) -> Bool {
        do {
            try token.write(toFile: liveTokenPath, atomically: true, encoding: .utf8)
            // Restrict to owner only (same as ~/.claude.json)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: liveTokenPath)
            log.info("[saveTokenToFile] Token saved to \(liveTokenPath)")
            return true
        } catch {
            log.error("[saveTokenToFile] Failed: \(error.localizedDescription)")
            return false
        }
    }

    func writeClaudeToken(_ token: String) -> Bool {
        // Keep the file in sync
        _ = saveTokenToFile(token)

        // Also write to keychain
        guard let data = token.data(using: .utf8) else {
            log.error("[writeClaudeToken] Failed to encode token as UTF-8")
            return false
        }

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeService,
            kSecAttrAccount as String: claudeAccount
        ]

        let updateAttrs: [String: Any] = [
            kSecValueData as String: data
        ]

        var status = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = searchQuery
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        let ok = status == errSecSuccess
        log.info("[writeClaudeToken] Result: \(ok) (status=\(status))")
        return ok
    }

    // MARK: - ~/.claude.json oauthAccount Operations

    func readOAuthAccount() -> [String: AnyCodable]? {
        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              let json = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              let oauthEntry = json["oauthAccount"],
              let dict = oauthEntry.value as? [String: AnyCodable] else {
            log.error("[readOAuthAccount] Failed to read oauthAccount from \(claudeJsonPath)")
            return nil
        }
        let email = (dict["emailAddress"]?.value as? String) ?? "?"
        log.info("[readOAuthAccount] Found: email=\(email)")
        return dict
    }

    /// Structured identity read from `~/.claude.json`'s `oauthAccount`.
    /// Replaces `claude auth status` identity fields removed in Claude Code v2.1.139.
    func readOAuthIdentity() -> OAuthIdentity? {
        guard let dict = readOAuthAccount() else { return nil }
        guard let email = dict["emailAddress"]?.value as? String else {
            log.error("[readOAuthIdentity] oauthAccount present but missing emailAddress")
            return nil
        }
        let identity = OAuthIdentity(
            emailAddress: email,
            displayName: dict["displayName"]?.value as? String,
            organizationName: dict["organizationName"]?.value as? String,
            organizationUuid: dict["organizationUuid"]?.value as? String,
            accountUuid: dict["accountUuid"]?.value as? String,
            organizationType: dict["organizationType"]?.value as? String,
            seatTier: dict["seatTier"]?.value as? String,
            billingType: dict["billingType"]?.value as? String,
            userRateLimitTier: dict["userRateLimitTier"]?.value as? String,
            organizationRateLimitTier: dict["organizationRateLimitTier"]?.value as? String,
            hasExtraUsageEnabled: dict["hasExtraUsageEnabled"]?.value as? Bool ?? false,
            accountCreatedAt: dict["accountCreatedAt"]?.value as? String,
            subscriptionCreatedAt: dict["subscriptionCreatedAt"]?.value as? String
        )
        log.info("[readOAuthIdentity] email=\(email), org=\(identity.organizationName ?? "nil"), sub=\(identity.subscriptionTypeLabel ?? "nil")")
        return identity
    }

    func writeOAuthAccount(_ oauthAccount: [String: AnyCodable]) -> Bool {
        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              var json = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            log.error("[writeOAuthAccount] Failed to read \(claudeJsonPath)")
            return false
        }

        json["oauthAccount"] = AnyCodable(oauthAccount)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let newData = try encoder.encode(json)
            try newData.write(to: URL(fileURLWithPath: claudeJsonPath), options: .atomic)
            let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
            log.info("[writeOAuthAccount] Written: email=\(email)")
            return true
        } catch {
            log.error("[writeOAuthAccount] Failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Account Backup Operations (token + oauthAccount)

    func saveAccountBackup(token: String, oauthAccount: [String: AnyCodable], forAccountId accountId: String) -> Bool {
        let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
        log.info("[saveBackup] Saving for \(accountId) (\(email)), token length=\(token.count)")
        var store = loadBackupStore()
        store[accountId] = AccountBackup(token: token, oauthAccount: oauthAccount)
        let result = saveBackupStore(store)
        log.info("[saveBackup] Result: \(result)")
        return result
    }

    func getAccountBackup(forAccountId accountId: String) -> AccountBackup? {
        let store = loadBackupStore()
        let backup = store[accountId]
        if let backup {
            let email = (backup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
            log.info("[getBackup] Found for \(accountId) (\(email)), token length=\(backup.token.count)")
        } else {
            log.error("[getBackup] No backup for accountId=\(accountId)")
        }
        return backup
    }

    @discardableResult
    func removeAccountBackup(forAccountId accountId: String) -> Bool {
        log.info("[removeBackup] Removing for accountId=\(accountId)")
        var store = loadBackupStore()
        store.removeValue(forKey: accountId)
        return saveBackupStore(store)
    }

    // Legacy compatibility — read token string only (for diagnostics)
    func getAccountToken(forAccountId accountId: String) -> String? {
        return getAccountBackup(forAccountId: accountId)?.token
    }

    // MARK: - Backup Store (file-based — survives rebuilds and CC auto-updates)

    private func loadBackupStore() -> [String: AccountBackup] {
        guard FileManager.default.fileExists(atPath: backupsFilePath),
              let data = FileManager.default.contents(atPath: backupsFilePath),
              let dict = try? JSONDecoder().decode([String: AccountBackup].self, from: data) else {
            log.debug("[loadBackupStore] No existing backups at \(backupsFilePath)")
            return [:]
        }
        log.debug("[loadBackupStore] Loaded \(dict.count) entries from file")
        return dict
    }

    private func saveBackupStore(_ store: [String: AccountBackup]) -> Bool {
        do {
            let data = try JSONEncoder().encode(store)
            try data.write(to: URL(fileURLWithPath: backupsFilePath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupsFilePath)
            log.debug("[saveBackupStore] Saved \(store.count) entries to file")
            return true
        } catch {
            log.error("[saveBackupStore] Failed to write \(backupsFilePath): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Refreshed-credential persistence (rotation-safe)

    /// Merge rotated creds into a token-JSON string, PRESERVING every other field
    /// (mcpOAuth, claudeAiOauth.scopes / subscriptionType / rateLimitTier). Returns the
    /// new JSON string, or nil if the input is not the expected shape.
    private func mergeRefreshedCreds(into tokenJSON: String, creds: RefreshedCreds) -> String? {
        guard let data = tokenJSON.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("[mergeRefreshed] token JSON not an object — cannot merge")
            return nil
        }
        var oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = creds.accessToken
        oauth["refreshToken"] = creds.refreshToken
        oauth["expiresAt"] = creds.expiresAtMillis
        root["claudeAiOauth"] = oauth
        guard let newData = try? JSONSerialization.data(withJSONObject: root),
              let newStr = String(data: newData, encoding: .utf8) else {
            log.error("[mergeRefreshed] re-encode failed")
            return nil
        }
        return newStr
    }

    /// Atomically persist rotated creds. ROTATION-SAFETY: the new refresh token must
    /// be written to durable storage BEFORE the caller discards the old one. Always
    /// updates the per-account backup store; if `isActive`, also syncs the live keychain
    /// + token file. Returns false on ANY write failure — the caller MUST treat false as
    /// fatal and NOT proceed as though the refresh succeeded.
    func persistRefreshedCreds(_ creds: RefreshedCreds, forAccountId accountId: String, isActive: Bool) -> Bool {
        var store = loadBackupStore()
        guard let backup = store[accountId] else {
            log.error("[persistRefreshed] No backup for \(accountId) — cannot persist rotated creds")
            return false
        }
        guard let newToken = mergeRefreshedCreds(into: backup.token, creds: creds) else {
            return false
        }
        store[accountId] = AccountBackup(token: newToken, oauthAccount: backup.oauthAccount)

        // ORDERING (rotation-safety, reviewer Finding #1): for the ACTIVE account the
        // live keychain is what the running `claude` CLI reads. Write it FIRST so that a
        // partial failure leaves the STILL-OLD backup intact (recoverable on next switch)
        // rather than a backup-holds-new / keychain-holds-dead split where the CLI is stuck
        // on a server-invalidated token and the fresh-looking backup suppresses retry.
        if isActive {
            guard writeClaudeToken(newToken) else {
                log.error("[persistRefreshed] Active keychain write failed for \(accountId) — backup left unchanged (recoverable)")
                return false
            }
        }
        guard saveBackupStore(store) else {
            // Active: keychain already holds the fresh token so the CLI works; backup is
            // stale-but-self-heals on next capture. Inactive: nothing was written live.
            log.error("[persistRefreshed] Backup store write failed for \(accountId) (active=\(isActive))")
            return false
        }
        log.info("[persistRefreshed] Rotated creds persisted for \(accountId) (active=\(isActive))")
        return true
    }

}
