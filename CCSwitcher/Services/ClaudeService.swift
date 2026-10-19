import Foundation

private let log = FileLog("Claude")

/// UserDefaults key holding the user's preferred Claude CLI path (empty = auto).
let kClaudeBinaryPathPreferenceKey = "claudeBinaryPathPreference"

/// A claude binary discovered on this Mac.
struct DetectedClaudePath: Hashable, Identifiable {
    let path: String
    let label: String
    var id: String { path }
}

/// Interacts with the Claude CLI to get auth status and manage accounts.
final class ClaudeService: @unchecked Sendable {
    static let shared = ClaudeService()

    private let lock = NSLock()
    private var _claudePath: String
    /// Monotonic counter to detect out-of-order setPath completions.
    private var _setPathGeneration: UInt64 = 0

    /// Currently active path. Thread-safe.
    var claudePath: String {
        lock.lock(); defer { lock.unlock() }
        return _claudePath
    }

    /// Token-refresh strategy. Option A (direct OAuth grant) by default; swap to an
    /// Option B implementation here if the edge starts attestation-blocking (HTTP 403
    /// 1010). See ARCHITECTURE.md §Token Lifecycle & Refresh.
    let refresher: any TokenRefreshing = DirectTokenRefresher()

    private init() {
        let preference = UserDefaults.standard.string(forKey: kClaudeBinaryPathPreferenceKey) ?? ""
        if !preference.isEmpty, FileManager.default.isExecutableFile(atPath: preference) {
            self._claudePath = preference
            log.info("Claude binary path: \(preference) (user preference)")
        } else {
            let auto = Self.autoSelectedPath()
            self._claudePath = auto.path
            log.info("Claude binary path: \(auto.path) (\(auto.source))")
            if !preference.isEmpty {
                log.warning("Saved preference \(preference) is no longer valid; falling back to auto")
            }
        }
    }

    /// Update the runtime claude path. Pass nil or empty to revert to auto-detection.
    /// Does NOT validate — caller (Settings UI) is expected to validate before calling.
    /// Auto-resolution happens outside the lock (can take ~3s via shell PATH lookup);
    /// a generation counter ensures a slower call cannot overwrite a faster, later one.
    func setPath(_ override: String?) {
        lock.lock()
        _setPathGeneration &+= 1
        let myGen = _setPathGeneration
        lock.unlock()

        let resolved: (String, String)
        if let override, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            resolved = (override, "override")
        } else {
            let auto = Self.autoSelectedPath()
            resolved = (auto.path, "auto/\(auto.source)")
        }

        lock.lock()
        guard myGen == _setPathGeneration else {
            lock.unlock()
            log.info("[setPath] superseded by newer call, discarding \(resolved.0)")
            return
        }
        _claudePath = resolved.0
        lock.unlock()
        log.info("[setPath] \(resolved.1): \(resolved.0)")
    }

    // MARK: - Detection

    /// Today's 3-tier fallback: curated → shell PATH → bare "claude".
    static func autoSelectedPath() -> (path: String, source: String) {
        for candidate in curatedPathCandidates() where FileManager.default.fileExists(atPath: candidate) {
            return (candidate, "curated")
        }
        if let shellPath = shellPathLookup() {
            return (shellPath, "shell PATH")
        }
        return ("claude", "fallback")
    }

    /// All claude binaries that actually exist on this Mac, deduplicated by
    /// resolved symlink target, ordered by discovery source.
    static func detectedPaths() -> [DetectedClaudePath] {
        var result: [DetectedClaudePath] = []
        var seenResolved = Set<String>()

        func add(_ path: String, _ label: String) {
            guard FileManager.default.fileExists(atPath: path) else { return }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard !seenResolved.contains(resolved) else { return }
            seenResolved.insert(resolved)
            result.append(DetectedClaudePath(path: path, label: label))
        }

        for (path, label) in curatedLabeledCandidates() {
            add(path, label)
        }
        for (path, label) in nvmLabeledCandidates() {
            add(path, label)
        }
        if let shellPath = shellPathLookup() {
            add(shellPath, "From shell PATH")
        }

        return result
    }

    private static func curatedPathCandidates() -> [String] {
        curatedLabeledCandidates().map { $0.0 } + nvmLabeledCandidates().map { $0.0 }
    }

    private static func curatedLabeledCandidates() -> [(String, String)] {
        let home = NSHomeDirectory()
        return [
            ("/usr/local/bin/claude", "/usr/local/bin"),
            ("/opt/homebrew/bin/claude", "Homebrew"),
            ("/opt/local/bin/claude", "MacPorts"),
            ("\(home)/.local/bin/claude", "Anthropic native installer"),
            ("\(home)/.claude/local/claude", "Anthropic migrate installer"),
            ("\(home)/.npm-global/bin/claude", "npm global"),
            ("\(home)/.volta/bin/claude", "Volta"),
            ("\(home)/Library/pnpm/claude", "pnpm"),
            ("\(home)/.bun/bin/claude", "Bun"),
            ("\(home)/.yarn/bin/claude", "Yarn"),
        ]
    }

    /// Discover Claude binaries installed via NVM (Node Version Manager).
    /// NVM stores node versions at ~/.nvm/versions/node/<version>/bin/.
    private static func nvmLabeledCandidates() -> [(String, String)] {
        let nvmDir = "\(NSHomeDirectory())/.nvm/versions/node"
        guard FileManager.default.fileExists(atPath: nvmDir) else { return [] }
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) else {
            log.warning("[nvmLabeledCandidates] NVM directory exists but could not be read: \(nvmDir)")
            return []
        }
        return versions
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { ("\(nvmDir)/\($0)/bin/claude", "NVM \($0)") }
    }

    /// Last-resort lookup: ask the user's interactive login shell where `claude` lives.
    /// Catches install layouts the curated list doesn't enumerate (asdf shims, fnm, n,
    /// pnpm/yarn/bun/Volta with non-default prefixes, custom npm prefixes, etc.).
    /// Bounded by a short timeout so a slow .zshrc can't block app launch.
    private static func shellPathLookup() -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v claude"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            log.warning("[shellPathLookup] Failed to launch /bin/zsh: \(error.localizedDescription)")
            return nil
        }

        // Hard timeout — don't let a heavy shell rc file block forever.
        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            log.warning("[shellPathLookup] zsh exceeded 3s timeout; aborting")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        // `command -v` may emit multiple lines if claude is shadowed; take the first.
        let candidate = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard candidate.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: candidate) else {
            return nil
        }
        return candidate
    }

    // MARK: - Auth Status

    func getAuthStatus() async throws -> AuthStatus {
        log.info("[getAuthStatus] Fetching auth status...")
        let output = try await runClaude(args: ["auth", "status"])
        guard let data = output.data(using: .utf8) else {
            log.error("[getAuthStatus] Invalid output (not UTF-8)")
            throw ClaudeServiceError.invalidOutput
        }
        let status = try JSONDecoder().decode(AuthStatus.self, from: data)
        log.info("[getAuthStatus] loggedIn=\(status.loggedIn), method=\(status.authMethod ?? "nil"), provider=\(status.apiProvider ?? "nil")")
        return status
    }

    func isClaudeAvailable() async -> Bool {
        do {
            let version = try await runClaude(args: ["--version"])
            log.info("[isClaudeAvailable] YES, version: \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
            return true
        } catch {
            log.error("[isClaudeAvailable] NO, error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Usage API

    enum UsageError: Error {
        case expired
        case network(String)
        case decode(String)
        case rateLimited(retryAfter: TimeInterval?)
        /// 403 permission_error - e.g. "OAuth authentication is currently not
        /// allowed for this organization" (no active Pro/Max subscription).
        case forbidden(String)
    }

    /// Fetch usage for a specific access token
    func getUsageLimits(accessToken: String) async throws -> UsageAPIResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { throw UsageError.network("invalid url") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        log.debug("[getUsageLimits] REQUEST URL: \(url.absoluteString)")

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard httpResponse?.statusCode == 200 else {
            let responseString = String(data: responseData, encoding: .utf8) ?? ""
            log.error("[getUsageLimits] HTTP \(httpResponse?.statusCode ?? 0)")

            if httpResponse?.statusCode == 401 || responseString.contains("token_expired") {
                throw UsageError.expired
            }
            if httpResponse?.statusCode == 429 {
                let retryAfter = httpResponse?.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
                log.warning("[getUsageLimits] 429, Retry-After: \(retryAfter.map { String(format: "%.0f", $0) } ?? "none")s")
                throw UsageError.rateLimited(retryAfter: retryAfter)
            }
            if httpResponse?.statusCode == 403 {
                // Typically: no active Pro/Max subscription on the account.
                log.warning("[getUsageLimits] 403 permission error: \(responseString.prefix(200))")
                throw UsageError.forbidden(responseString)
            }
            throw UsageError.network("HTTP \(httpResponse?.statusCode ?? 0)")
        }
        
        do {
            let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: responseData)
            log.info("[getUsageLimits] session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
            return usage
        } catch {
            log.error("[getUsageLimits] Decode Error: \(error.localizedDescription)")
            throw UsageError.decode(error.localizedDescription)
        }
    }

    /// Extract access token string from a token JSON (keychain format)
    static func extractAccessToken(from tokenJSON: String) -> String? {
        return oauthField(from: tokenJSON, key: "accessToken") as? String
    }

    /// Extract the refresh token from a token JSON. Needed to drive the refresh grant.
    static func extractRefreshToken(from tokenJSON: String) -> String? {
        return oauthField(from: tokenJSON, key: "refreshToken") as? String
    }

    /// Extract `expiresAt` (epoch ms) from a token JSON. Used to decide proactive refresh.
    /// Tolerates Int or Double encodings.
    static func extractExpiresAt(from tokenJSON: String) -> Double? {
        switch oauthField(from: tokenJSON, key: "expiresAt") {
        case let d as Double: return d
        case let i as Int:    return Double(i)
        default:              return nil
        }
    }

    private static func oauthField(from tokenJSON: String, key: String) -> Any? {
        guard let data = tokenJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        return oauth[key]
    }

    // MARK: - Cloud-feature scope probe

    /// Result of probing whether a token has the modern OAuth scopes required
    /// for Claude Code on the web (e.g. /ultraplan, /ultrareview, remote sessions).
    enum ScopeProbeResult: Sendable {
        /// Token is valid and has cloud-session scopes.
        case ok
        /// Token authenticates but lacks the scopes for cloud features.
        /// Re-authentication is required (refresh_token cannot upgrade scopes per OAuth 2.0).
        case staleScope
        /// Server rejected the token (401). Refresh token expired or was rotated/revoked
        /// while this snapshot was sitting in CCSwitcher's backup. Re-auth required;
        /// proceeding would corrupt the live keychain with a token the API will refuse.
        case expired
        /// Network or transient error. Caller should fall through, not block.
        case transientError
    }

    /// Probes /v1/environment_providers to determine whether `accessToken` has
    /// the modern OAuth scopes Claude Code's cloud features require.
    /// Read-only HTTPS GET; no side effects on Anthropic side.
    /// Throws `CancellationError` if the surrounding Task is cancelled — never
    /// swallows cancellation as a "transient" outcome.
    func probeCloudScopes(accessToken: String) async throws -> ScopeProbeResult {
        guard let url = URL(string: "https://api.anthropic.com/v1/environment_providers") else {
            return .transientError
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                log.warning("[probeCloudScopes] non-HTTP response, treating as transient")
                return .transientError
            }
            switch http.statusCode {
            case 200:
                log.info("[probeCloudScopes] HTTP 200 — cloud scopes present")
                return .ok
            case 401:
                // Server rejected the bearer. The snapshot CCSwitcher is about to write
                // is already invalid — writing it would leave Claude Code in the 401
                // loop the user is currently seeing. Halt and route to re-auth.
                let body = String(data: data, encoding: .utf8) ?? ""
                log.error("[probeCloudScopes] HTTP 401 — token expired/revoked. body=\(body.prefix(200))")
                return .expired
            case 403:
                let body = String(data: data, encoding: .utf8) ?? ""
                if body.contains("OAuth token does not meet scope requirement") {
                    log.warning("[probeCloudScopes] HTTP 403 stale-scope — token needs re-auth")
                    return .staleScope
                }
                // Future-proof: if Anthropic changes wording, surface the body so we can
                // fix-forward. body.prefix(200) keeps the log line bounded.
                log.warning("[probeCloudScopes] HTTP 403 (non-scope match) — body: \(body.prefix(200))")
                return .transientError
            default:
                log.warning("[probeCloudScopes] HTTP \(http.statusCode) — transient")
                return .transientError
            }
        } catch is CancellationError {
            // Structured-concurrency contract: cancellation must propagate, never be
            // swallowed as a "transient" outcome. Otherwise a cancelled probe could
            // let switchAccount() proceed with an unverified token (DeepSeek finding #1).
            throw CancellationError()
        } catch {
            log.warning("[probeCloudScopes] error: \(error.localizedDescription) — transient")
            return .transientError
        }
    }

    // MARK: - Account Switching

    /// Result of a completed switch.
    struct SwitchOutcome {
        /// Set when the swap succeeded but `claude auth status` could not confirm
        /// it, because this credential source shadows the stored claude.ai login.
        let shadowedBy: String?
    }

    /// `targetBackup` is resolved by the caller (which can distinguish a
    /// missing backup from a briefly unreadable store) and handed down so no
    /// second, ambiguity-collapsing lookup happens here.
    @discardableResult
    func switchAccount(from currentAccount: Account, to targetAccount: Account, targetBackup: AccountBackup) async throws -> SwitchOutcome {
        let keychain = KeychainService.shared

        log.info("[switchAccount] Switching from \(currentAccount.id) to \(targetAccount.id)")

        // 1. Back up current account (token + oauthAccount)
        log.info("[switchAccount] Step 1: Backing up current account...")
        if let currentToken = keychain.readClaudeToken(),
           let currentOAuth = keychain.readOAuthAccount() {
            let email = (currentOAuth["emailAddress"]?.value as? String) ?? "?"
            if email == currentAccount.email {
                let saved = keychain.saveAccountBackup(token: currentToken, oauthAccount: currentOAuth, forAccountId: currentAccount.id.uuidString)
                log.info("[switchAccount] Step 1: Backup saved: \(saved)")
            } else {
                log.warning("[switchAccount] Step 1: oauthAccount email (\(email)) != source (\(currentAccount.email)), skipping backup")
            }
        } else {
            log.warning("[switchAccount] Step 1: Could not read current token or oauthAccount")
        }

        // 2. Target backup was resolved and validated by the caller.
        log.info("[switchAccount] Step 2: Using caller-resolved backup for target account")

        // Token actually written to the keychain in Step 3. Starts as the stored backup
        // token; if Step 2.5 refreshes an expired token, this is replaced with the fresh one.
        var workingToken = targetBackup.token

        // 2.5. Probe target token's cloud-feature scopes BEFORE writing to keychain.
        // OAuth 2.0 cannot upgrade scopes via refresh_token — a token minted before
        // a new scope existed will silently fail Claude Code's cloud features
        // (e.g. /ultraplan returns "session creation failed"). On stale-scope, halt
        // the swap so the user re-authenticates instead of writing a broken token.
        // See AppState.reauthenticateAccount; UI is in AccountSwitcherView.swift:141.
        log.info("[switchAccount] Step 2.5: Probing target token cloud scopes...")
        if let probeAccessToken = ClaudeService.extractAccessToken(from: targetBackup.token) {
            // `try` lets CancellationError propagate up; AppState.switchTo catches it
            // and surfaces a clean error to the user instead of silently corrupting
            // the live keychain entry with an unverified token.
            switch try await probeCloudScopes(accessToken: probeAccessToken) {
            case .ok:
                log.info("[switchAccount] Step 2.5: cloud scopes OK")
            case .staleScope:
                log.error("[switchAccount] Step 2.5: stale-scope — halting swap before keychain write")
                throw ClaudeServiceError.staleScope(email: targetAccount.email)
            case .expired:
                // NEW (2026-06-06): instead of halting, attempt a refresh-token grant.
                // Anthropic refresh tokens rotate, so the access token expiring does NOT
                // mean the account is dead — the stored refresh token may still mint a
                // fresh access token. Only halt to re-auth if the refresh itself fails.
                log.warning("[switchAccount] Step 2.5: access token expired — attempting refresh-grant")
                guard let refreshTok = ClaudeService.extractRefreshToken(from: workingToken) else {
                    log.error("[switchAccount] Step 2.5: no refresh token in backup — re-auth required")
                    throw ClaudeServiceError.expiredToken(email: targetAccount.email)
                }
                do {
                    let creds = try await refresher.refresh(refreshToken: refreshTok)
                    // ROTATION-SAFETY: persist the rotated token to the backup store BEFORE
                    // using it. isActive:false — target is not the live account until Step 3.
                    guard keychain.persistRefreshedCreds(creds, forAccountId: targetAccount.id.uuidString, isActive: false),
                          let refreshed = keychain.getAccountBackup(forAccountId: targetAccount.id.uuidString) else {
                        log.error("[switchAccount] Step 2.5: refresh succeeded but persist/reread failed — re-auth required")
                        throw ClaudeServiceError.expiredToken(email: targetAccount.email)
                    }
                    workingToken = refreshed.token
                    log.info("[switchAccount] Step 2.5: refresh succeeded — proceeding with fresh token")
                } catch let refreshErr as TokenRefreshError {
                    log.error("[switchAccount] Step 2.5: refresh failed (\(refreshErr.localizedDescription)) — re-auth required")
                    throw ClaudeServiceError.expiredToken(email: targetAccount.email)
                }
            case .transientError:
                log.warning("[switchAccount] Step 2.5: probe inconclusive — proceeding (fail-open)")
            }
        } else {
            log.warning("[switchAccount] Step 2.5: could not extract accessToken from backup, skipping probe")
        }

        // 3. Write target token to keychain + target oauthAccount to ~/.claude.json
        log.info("[switchAccount] Step 3: Writing target credentials...")
        guard keychain.writeClaudeToken(workingToken) else {
            log.error("[switchAccount] Step 3: Failed to write token to keychain!")
            throw ClaudeServiceError.keychainWriteFailed
        }
        guard keychain.writeOAuthAccount(targetBackup.oauthAccount) else {
            log.error("[switchAccount] Step 3: Failed to write oauthAccount to ~/.claude.json!")
            throw ClaudeServiceError.oauthAccountWriteFailed
        }
        log.info("[switchAccount] Step 3: Both token and oauthAccount written")

        // 4. Verify identity from ~/.claude.json (the file we just wrote in Step 3).
        // We read it back directly — no subprocess needed. `claude auth status` can
        // hang for 12+ seconds on expired tokens (internal refresh deadlock, exit 1)
        // and is no longer the canonical identity source since v2.1.139.
        log.info("[switchAccount] Step 4: Verifying identity from oauthAccount...")
        guard let identity = KeychainService.shared.readOAuthIdentity() else {
            log.error("[switchAccount] Step 4: Could not read oauthAccount identity after write")
            throw ClaudeServiceError.switchVerificationFailed
        }
        if identity.emailAddress != targetAccount.email {
            log.error("[switchAccount] Step 4: Identity mismatch — got \(identity.emailAddress), expected \(targetAccount.email)")
            throw ClaudeServiceError.switchWrongAccount(expected: targetAccount.email, actual: identity.emailAddress)
        }
        // D3: after a keychain write, confirm the keychain actually holds the token we
        // wrote (the refreshed one if Step 2.5 rotated it) before reporting success.
        guard keychainHolds(token: workingToken) else {
            throw ClaudeServiceError.switchVerificationFailed
        }
        // No `claude auth status` check here: the subprocess reads the keychain via
        // /usr/bin/security → user-facing popup on every switch, and it was already
        // non-fatal dead weight (failed exit-1 on 2026-06-06 while the switch verified
        // fine via the ~/.claude.json read above). Without it a credential source that
        // shadows the stored login (env token, apiKeyHelper, …) cannot be detected
        // here, so `shadowedBy` is always nil.
        log.info("[switchAccount] Step 4: Switch verified — logged in as \(identity.emailAddress)")
        return SwitchOutcome(shadowedBy: nil)
    }

    /// Ground-truth check that the live keychain holds `token`, compared by access
    /// token so formatting differences in the stored JSON do not matter.
    private func keychainHolds(token: String) -> Bool {
        guard let live = KeychainService.shared.readClaudeToken(),
              let liveAccess = Self.extractAccessToken(from: live),
              let expectedAccess = Self.extractAccessToken(from: token),
              liveAccess == expectedAccess else {
            log.error("[switchAccount] Step 4: Keychain token does not match the token just written")
            return false
        }
        return true
    }

    /// Capture the current Claude auth token + oauthAccount and associate with an account
    func captureCurrentCredentials(forAccountId accountId: String) -> Bool {
        log.info("[capture] Capturing credentials for account \(accountId)...")
        let keychain = KeychainService.shared
        guard let token = keychain.readClaudeToken() else {
            log.error("[capture] Failed: no token found in keychain")
            return false
        }
        guard let oauthAccount = keychain.readOAuthAccount() else {
            log.error("[capture] Failed: no oauthAccount found in ~/.claude.json")
            return false
        }
        let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
        log.info("[capture] Token + oauthAccount found (email=\(email)), saving backup...")
        let result = keychain.saveAccountBackup(token: token, oauthAccount: oauthAccount, forAccountId: accountId)
        log.info("[capture] Save result: \(result)")
        return result
    }

    /// Run `claude auth login` which opens browser for OAuth.
    func login() async throws {
        log.info("[login] Starting `claude auth login`... (will open browser)")
        _ = try await runClaude(args: ["auth", "login"])
        log.info("[login] `claude auth login` process exited")

        // Give keychain a moment to sync after CLI writes
        try await Task.sleep(for: .seconds(1))
        log.info("[login] Post-login delay complete, ready for token capture")
    }

    /// Run `claude auth logout`
    func logout() async throws {
        log.info("[logout] Running `claude auth logout`...")
        _ = try await runClaude(args: ["auth", "logout"])
        log.info("[logout] Logout complete")
    }

    // MARK: - Version

    /// Run `<path> --version` and return the first semver-looking token.
    /// Returns nil on launch failure, non-zero exit, or no version found.
    static func readVersion(at path: String) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["--version"]
                process.standardOutput = stdout
                process.standardError = Pipe()

                // Inject same PATH augmentation as runClaude so NVM-installed
                // claude can find `node` when invoked here.
                var env = ProcessInfo.processInfo.environment
                let homeDir = NSHomeDirectory()
                var extraPaths = [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "\(homeDir)/.local/bin",
                    "\(homeDir)/.npm-global/bin"
                ]
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                let resolvedBinDir = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
                extraPaths.insert(resolvedBinDir, at: 0)
                let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                env["HOME"] = homeDir
                process.environment = env

                do {
                    try process.run()
                } catch {
                    log.warning("[readVersion] launch failed for \(path): \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }

                let deadline = Date().addingTimeInterval(5.0)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    log.warning("[readVersion] timed out for \(path)")
                    continuation.resume(returning: nil)
                    return
                }

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: Self.extractSemver(from: raw))
            }
        }
    }

    /// Fetch the latest published claude-code version. Returns nil on any failure.
    static func fetchLatestVersion() async -> String? {
        guard let url = URL(string: "https://downloads.claude.ai/claude-code-releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log.warning("[fetchLatestVersion] non-200 response")
                return nil
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strict: the entire body must BE a semver. Protects against the CDN
            // returning an HTML error page with 200 status that happens to contain
            // dotted numbers (CSS dimensions, version strings in copy, etc.).
            return Self.isPureSemver(trimmed) ? trimmed : nil
        } catch {
            log.warning("[fetchLatestVersion] error: \(error.localizedDescription)")
            return nil
        }
    }

    /// True if the whole string is ASCII digits separated by dots (e.g. "1.0.42", "2.1.139").
    private static func isPureSemver(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 32 else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for p in parts {
            guard !p.isEmpty else { return false }
            for ch in p {
                guard ch.isASCII, ch.isNumber else { return false }
            }
        }
        return true
    }

    /// Extract the first dotted-ASCII-numeric token from a string (e.g. "1.0.42" out of "1.0.42 (Claude Code)").
    private static func extractSemver(from text: String) -> String? {
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isNumber || $0 == ".") }
        for token in text.split(whereSeparator: { !allowed($0) }) {
            let s = String(token)
            guard isPureSemver(s) else { continue }
            return s
        }
        return nil
    }

    // MARK: - CLI Runner

    private func runClaude(args: [String]) async throws -> String {
        let claudePath = self.claudePath
        log.debug("[runClaude] Running: \(claudePath) \(args.joined(separator: " "))")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [claudePath] in
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe

                var env = ProcessInfo.processInfo.environment
                let homeDir = NSHomeDirectory()
                // Include the parent directory of the discovered claude binary
                // so that `node` is on PATH for NVM-installed scripts.
                // Only add it when claudePath is absolute (skip the bare "claude" fallback).
                var extraPaths = [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "\(homeDir)/.local/bin",
                    "\(homeDir)/.npm-global/bin"
                ]
                if claudePath.contains("/") {
                    // Resolve symlinks so that e.g. /usr/local/bin/claude -> ~/.nvm/.../bin/claude
                    // yields the NVM bin dir where `node` actually lives
                    let resolved = URL(fileURLWithPath: claudePath).resolvingSymlinksInPath().path
                    let resolvedBinDir = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
                    extraPaths.insert(resolvedBinDir, at: 0)
                }
                let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                env["HOME"] = homeDir
                process.environment = env

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        log.debug("[runClaude] Success (exit 0), output length: \(output.count)")
                        continuation.resume(returning: output)
                    } else {
                        log.error("[runClaude] Failed (exit \(process.terminationStatus))")
                        continuation.resume(throwing: ClaudeServiceError.cliError("exit \(process.terminationStatus)"))
                    }
                } catch {
                    log.error("[runClaude] Process launch failed: \(error.localizedDescription)")
                    continuation.resume(throwing: ClaudeServiceError.processLaunchFailed(error))
                }
            }
        }
    }
}

// MARK: - Errors

enum ClaudeServiceError: LocalizedError {
    case invalidOutput
    case cliError(String)
    case processLaunchFailed(Error)
    case noTokenForAccount(String)
    case keychainWriteFailed
    case oauthAccountWriteFailed
    case switchVerificationFailed
    case switchWrongAccount(expected: String, actual: String)
    case staleScope(email: String)
    case expiredToken(email: String)

    /// D3 (ARCHITECTURE.md §Token Lifecycle): true ONLY for failures thrown after
    /// switchAccount Step 3 began writing the live keychain. Rollback is destructive
    /// for pre-write failures — restoring the backup over an untouched keychain
    /// clobbered a fresh CLI login with a stale token (observed 2026-06-06 12:02:56).
    var occurredAfterKeychainWrite: Bool {
        switch self {
        case .keychainWriteFailed, .oauthAccountWriteFailed,
             .switchVerificationFailed, .switchWrongAccount:
            return true
        case .invalidOutput, .cliError, .processLaunchFailed,
             .noTokenForAccount, .staleScope, .expiredToken:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidOutput:
            return "Invalid output from Claude CLI"
        case .cliError(let msg):
            return "Claude CLI error: \(msg)"
        case .processLaunchFailed(let error):
            return "Failed to launch Claude: \(error.localizedDescription)"
        case .noTokenForAccount:
            return "No stored backup for target account"
        case .keychainWriteFailed:
            return "Failed to write token to keychain"
        case .oauthAccountWriteFailed:
            return "Failed to write oauthAccount to ~/.claude.json"
        case .switchVerificationFailed:
            return "Account switch verification failed"
        case .switchWrongAccount(let expected, let actual):
            return "Switch failed: expected \(expected) but got \(actual). Try removing and re-adding the account."
        case .staleScope(let email):
            return "\(email)'s saved token is too old for cloud features (e.g. /ultraplan). Click \"Re-authenticate\" on this account to fix."
        case .expiredToken(let email):
            return "\(email)'s saved token has expired (refresh token rotated or revoked since last capture). Click \"Re-authenticate\" on this account to fix — no terminal /login needed."
        }
    }
}
