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
/// - Claude CLI's token: keychain ONLY (D1), read/write via `security` CLI subprocess
///   (partition-list correctness — see Token Operations section below).
/// - Claude CLI's identity: read/write oauthAccount in ~/.claude.json.
/// - Our backups: per-account {token, oauthAccount} in ~/.ccswitcher/backups.json (file, no keychain ACL).
final class KeychainService: Sendable {
    static let shared = KeychainService()

    private let claudeService = "Claude Code-credentials"
    private let claudeAccount: String
    private let backupsFilePath: String
    private let claudeJsonPath: String

    /// Serializes every access to the backup store. All backups live in ONE
    /// file (`~/.ccswitcher/backups.json`), so each mutation is load-whole-store -> mutate -> save-
    /// whole-store; two of those interleaving (AppState runs on the main actor,
    /// but `ClaudeService.switchAccount` runs off it) can silently drop another
    /// account's freshly written credentials.
    private let storeLock = NSLock()

    private init() {
        self.claudeAccount = NSUserName()

        let home = NSHomeDirectory()
        let dir = home + "/.ccswitcher"
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

        // D1 (ARCHITECTURE.md §Token Lifecycle): the keychain is the ONLY copy of the
        // live token. The legacy file mirror went stale after every CLI /login and
        // ~8h CLI self-refresh, poisoning every load-bearing read. Delete it forever.
        let legacyMirrorPath = dir + "/live-token.txt"
        if FileManager.default.fileExists(atPath: legacyMirrorPath) {
            try? FileManager.default.removeItem(atPath: legacyMirrorPath)
            log.info("init: Deleted legacy live-token.txt mirror (D1 single-source-of-truth)")
        }

        log.info("init: claudeAccount=\(claudeAccount), backupsFile=\(backupsFilePath)")
    }

    // MARK: - Claude Code Token Operations (keychain ONLY — D1 single source of truth)
    //
    // PARTITION-LIST RULE (the popup class, closed 2026-06-06): items written via the
    // `security` CLI carry the `apple-tool:` partition — the claude CLI (which reads
    // through /usr/bin/security) then reads them SILENTLY. Items written natively
    // (SecItemUpdate/Add) carry THIS app's partition — every CLI read then hits a
    // login-keychain password prompt that "Always Allow" cannot persist. So Claude's
    // item is read AND written via the `security` subprocess (upstream
    // XueshiQiao/CCSwitcher's mechanism, ported verbatim 2026-06-06).
    //
    // Token-in-argv tradeoff (accepted, documented): the token is visible in the
    // subprocess argv for its ~ms lifetime. The stdin `-i` alternative was probed
    // 2026-06-06 and CORRUPTS secrets containing backslashes (lexer strips them) —
    // a corrupted credential write logs the user out, strictly worse than the
    // argv exposure on a single-user machine.

    func readClaudeToken() -> String? {
        let token = runSecurity(args: [
            "find-generic-password",
            "-s", claudeService,
            "-a", claudeAccount,
            "-w"
        ])

        if let token {
            let sanitized = token.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("[readClaudeToken] Found via security CLI, length=\(sanitized.count)")
            return sanitized
        } else {
            log.error("[readClaudeToken] No token found via security CLI")
            return nil
        }
    }

    func writeClaudeToken(_ token: String) -> Bool {
        // Delete then add (security CLI has no pure "update" for generic passwords).
        // -U on add is belt-and-braces if the delete raced a concurrent re-create.
        _ = runSecurityStatus(args: ["delete-generic-password", "-s", claudeService, "-a", claudeAccount])

        let added = runSecurityStatus(args: [
            "add-generic-password",
            "-s", claudeService,
            "-a", claudeAccount,
            "-w", token,
            "-U"
        ])
        log.info("[writeClaudeToken] Result: \(added)")
        return added
    }

    // MARK: - `security` CLI subprocess (Claude's item ONLY — see partition-list rule above)

    private func runSecurity(args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                log.debug("[runSecurity] Exit \(process.terminationStatus) for: security \(args.prefix(2).joined(separator: " "))...")
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == true ? nil : output
        } catch {
            log.error("[runSecurity] Launch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func runSecurityStatus(args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            if !ok {
                log.debug("[runSecurityStatus] Exit \(process.terminationStatus) for: security \(args.prefix(2).joined(separator: " "))...")
            }
            return ok
        } catch {
            log.error("[runSecurityStatus] Launch failed: \(error.localizedDescription)")
            return false
        }
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
        storeLock.lock()
        defer { storeLock.unlock() }
        var store: [String: AccountBackup]
        switch loadBackupStore() {
        case .loaded(let dict): store = dict
        case .empty: store = [:]
        case .failed(let reason):
            // Writing a mutated copy back after a failed load would replace
            // EVERY account's credentials with just this one entry. Refuse.
            log.error("[saveBackup] REFUSED: store unreadable (\(reason)); writing now would destroy the other accounts' backups")
            return false
        }
        store[accountId] = AccountBackup(token: token, oauthAccount: oauthAccount)
        let result = saveBackupStore(store)
        log.info("[saveBackup] Result: \(result)")
        return result
    }

    /// Result of looking up one account's backup. "The entry does not exist"
    /// and "the store could not be read right now" are different answers with
    /// different remedies (re-authenticate vs simply try again later), so the
    /// distinction is kept at the public boundary instead of collapsing both
    /// into nil.
    enum BackupLookup {
        case found(AccountBackup)
        case missing
        case storeUnavailable
    }

    func lookupAccountBackup(forAccountId accountId: String) -> BackupLookup {
        storeLock.lock()
        defer { storeLock.unlock() }
        switch loadBackupStore() {
        case .loaded(let store):
            guard let backup = store[accountId] else {
                log.error("[getBackup] No backup for accountId=\(accountId)")
                return .missing
            }
            // Account id only — no email in logs (HARD RULE 6); the id is a
            // locally-minted UUID that correlates log lines without
            // identifying anyone.
            log.info("[getBackup] Found for \(accountId), credential length=\(backup.token.count)")
            return .found(backup)
        case .empty:
            log.error("[getBackup] No backup for accountId=\(accountId) (store is empty)")
            return .missing
        case .failed(let reason):
            log.error("[getBackup] Store unreadable (\(reason)); \(accountId) unavailable until it recovers")
            return .storeUnavailable
        }
    }

    /// Convenience for call sites where "missing" and "unavailable" demand the
    /// same behavior (skip / treat as not switchable). Paths that tell the user
    /// what to DO about it must use `lookupAccountBackup` instead.
    func getAccountBackup(forAccountId accountId: String) -> AccountBackup? {
        if case .found(let backup) = lookupAccountBackup(forAccountId: accountId) {
            return backup
        }
        return nil
    }

    @discardableResult
    func removeAccountBackup(forAccountId accountId: String) -> Bool {
        log.info("[removeBackup] Removing for accountId=\(accountId)")
        storeLock.lock()
        defer { storeLock.unlock() }
        var store: [String: AccountBackup]
        switch loadBackupStore() {
        case .loaded(let dict): store = dict
        case .empty: return true
        case .failed(let reason):
            log.error("[removeBackup] REFUSED: store unreadable (\(reason)); writing now would destroy the other accounts' backups")
            return false
        }
        store.removeValue(forKey: accountId)
        return saveBackupStore(store)
    }

    // Legacy compatibility — read token string only (for diagnostics)
    func getAccountToken(forAccountId accountId: String) -> String? {
        return getAccountBackup(forAccountId: accountId)?.token
    }

    // MARK: - Backup Store (file-based — survives rebuilds and CC auto-updates)

    /// Result of reading the backup file. The `empty`/`failed` distinction is
    /// load-bearing: `empty` means the file genuinely does not exist yet, while
    /// `failed` means it exists but could not be read or decoded. Mutating "what we
    /// loaded" after a failed load and saving it back would truncate the store to
    /// the single entry being saved, destroying every other account's credentials.
    private enum BackupStoreLoad {
        case loaded([String: AccountBackup])
        case empty
        case failed(String)
    }

    /// Must be called with `storeLock` held.
    private func loadBackupStore() -> BackupStoreLoad {
        guard FileManager.default.fileExists(atPath: backupsFilePath) else {
            log.debug("[loadBackupStore] No existing backups at \(backupsFilePath)")
            return .empty
        }
        guard let data = FileManager.default.contents(atPath: backupsFilePath) else {
            log.error("[loadBackupStore] backups.json exists but could not be read")
            return .failed("backups.json unreadable")
        }
        guard let dict = try? JSONDecoder().decode([String: AccountBackup].self, from: data) else {
            // Data exists but we can't parse it. It is NOT gone — refuse to treat it
            // as empty so nothing ever writes over it.
            log.error("[loadBackupStore] backups.json exists (\(data.count) bytes) but did not decode")
            return .failed("undecodable store data")
        }
        log.debug("[loadBackupStore] Loaded \(dict.count) entries from file")
        return .loaded(dict)
    }

    /// Must be called with `storeLock` held.
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
        storeLock.lock()
        defer { storeLock.unlock() }
        var store: [String: AccountBackup]
        switch loadBackupStore() {
        case .loaded(let dict): store = dict
        case .empty: store = [:]
        case .failed(let reason):
            log.error("[persistRefreshed] REFUSED: store unreadable (\(reason)); cannot persist rotated creds for \(accountId)")
            return false
        }
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
