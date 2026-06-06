import SwiftUI
import Combine
import WidgetKit

private let log = FileLog("AppState")

/// Central app state managing accounts, usage data, and active sessions.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var activeAccount: Account?
    @Published var accountUsage: [UUID: UsageAPIResponse] = [:]
    @Published var usageSummary: UsageSummary = .empty
    @Published var recentActivity: [DailyActivity] = []
    @Published var activeSessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var isLoggingIn = false
    @Published var errorMessage: String?
    @Published var claudeAvailable = false
    @Published var lastUsageRefresh: Date?
    @Published var costSummary: CostSummary = .empty
    @Published var activityStats: ActivityStats = .empty

    // Store errors as special struct to surface in UI
    struct UsageErrorState {
        let isExpired: Bool
        let isRateLimited: Bool
        let message: String
    }
    
    @Published var accountUsageErrors: [UUID: UsageErrorState] = [:]

    // MARK: - Services

    private let claudeService = ClaudeService.shared
    private let statsParser = StatsParser.shared
    private let costParser = CostParser.shared
    private let activityParser = ActivityParser.shared
    private let keychain = KeychainService.shared

    private let accountsKey = "com.ccswitcher.accounts"
    private var refreshTimer: Timer?

    /// Reentrancy guard for switchTo. Distinct from `isLoading` (which is also set
    /// by `refresh()` running in parallel) so that auto-refresh doesn't silently
    /// swallow account-switch clicks. Not @Published — UI doesn't observe it.
    /// DeepSeek v2 finding #1.
    private var isSwitching = false

    /// Accounts with an in-flight refresh-grant. Because refresh tokens are single-use
    /// (rotated server-side), two concurrent grants for the same account would make the
    /// second fail with invalid_grant on a token the first already rotated away. Set on
    /// the MainActor before each grant, cleared after. Reviewer Finding #2.
    private var refreshingAccounts: Set<UUID> = []

    // MARK: - Initialization

    init() {
        log.info("[init] Loading accounts from UserDefaults...")
        loadAccounts()
        log.info("[init] Loaded \(self.accounts.count) accounts, active: \(self.activeAccount?.id.uuidString ?? "none")")
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isLoggingIn else {
            log.info("[refresh] Skipping: login in progress")
            return
        }
        isLoading = true
        errorMessage = nil

        claudeAvailable = await claudeService.isClaudeAvailable()
        log.info("[refresh] Claude available: \(self.claudeAvailable)")

        if claudeAvailable {
            // POPUP-FREE HOT PATH: do NOT spawn `claude auth status` here. The CLI
            // subprocess reads the keychain via /usr/bin/security, which macOS
            // trust-evaluates separately from this app → the recurring "security
            // wants to access" popup, once per refresh cycle. Identity already
            // lives in ~/.claude.json (canonical since CC v2.1.139) — read it
            // directly. `claude auth status` remains ONLY in user-initiated flows
            // (add/login/reauth), where one popup after an explicit action is fine.
            if keychain.readOAuthIdentity() != nil {
                let passiveStatus = AuthStatus(
                    loggedIn: true, authMethod: nil, apiProvider: nil,
                    email: nil, orgId: nil, orgName: nil, subscriptionType: nil
                )
                updateActiveAccount(from: passiveStatus)
            } else {
                log.info("[refresh] No oauthAccount in ~/.claude.json — treating as logged out (no CLI spawn)")
            }
        }

        // Passive token health check (no CLI calls, keychain reads only)
        diagnoseTokenHealth()

        // Proactively refresh any token nearing expiry so the live token stays valid
        // (keeps usage/cost working) and inactive backups stay switch-ready. Cheap:
        // only fires a network grant when a token is within SKEW of expiry (~once/8h).
        await refreshExpiringTokens()

        // Fetch usage limits for all accounts
        await fetchAllAccountUsage()
        lastUsageRefresh = Date()

        usageSummary = statsParser.getUsageSummary()
        recentActivity = statsParser.getRecentActivity(days: 7)
        activeSessions = statsParser.getActiveSessions()

        // JSONL parsing: walk filesystem once via the shared cache, then
        // pull aggregated outputs. The actor's executor is off the main
        // thread, so awaiting these does not block the UI.
        await SessionParseCache.shared.refreshFromFilesystem()
        let cost = await costParser.getCostSummary()
        let activity = await activityParser.getTodayStats()
        costSummary = cost
        activityStats = activity

        log.info("[refresh] Usage: weekly=\(self.usageSummary.weeklyMessages) msgs, \(self.activeSessions.count) active sessions, today=$\(String(format: "%.2f", cost.todayCost)) turns=\(activity.conversationTurns)")

        updateWidgetData()
        isLoading = false
    }

    func startAutoRefresh(interval: TimeInterval = 300) {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Account Management

    func addAccount() async {
        log.info("[addAccount] Starting add current account flow...")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[addAccount] Aborted: Claude CLI not found")
            return
        }

        do {
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn else {
                errorMessage = String(localized: "Not logged in to Claude. Run 'claude auth login' first.", bundle: L10n.bundle)
                log.error("[addAccount] Aborted: not logged in")
                return
            }
            guard let identity = keychain.readOAuthIdentity() else {
                errorMessage = String(localized: "Could not read account identity from ~/.claude.json", bundle: L10n.bundle)
                log.error("[addAccount] Aborted: no oauthAccount identity")
                return
            }
            let email = identity.emailAddress
            log.info("[addAccount] Current auth: logged in, sub=\(identity.subscriptionTypeLabel ?? "nil")")

            if accounts.contains(where: { $0.email == email }) {
                errorMessage = String(localized: "Account already exists", bundle: L10n.bundle)
                log.warning("[addAccount] Aborted: duplicate account")
                return
            }

            var account = Account(
                email: email,
                displayName: identity.organizationName ?? email,
                provider: .claudeCode,
                orgName: identity.organizationName,
                subscriptionType: identity.subscriptionTypeLabel,
                isActive: accounts.isEmpty
            )
            log.info("[addAccount] Created account model, id=\(account.id)")

            log.info("[addAccount] Capturing token from keychain...")
            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = String(localized: "Could not capture auth token from keychain", bundle: L10n.bundle)
                log.error("[addAccount] Token capture failed!")
                return
            }
            log.info("[addAccount] Token captured successfully")

            if accounts.isEmpty {
                account.isActive = true
                activeAccount = account
                log.info("[addAccount] First account, setting as active")
            }

            accounts.append(account)
            saveAccounts()
            log.info("[addAccount] Account saved. Total accounts: \(self.accounts.count)")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[addAccount] Error: \(error.localizedDescription)")
        }
    }

    func loginNewAccount() async {
        log.info("[loginNewAccount] ===== Starting login new account flow =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[loginNewAccount] Aborted: Claude CLI not found")
            return
        }

        isLoggingIn = true
        errorMessage = nil

        do {
            // 1. Back up current account (token + oauthAccount) before login overwrites them
            if let current = activeAccount {
                log.info("[loginNewAccount] Step 1: Backing up current account (\(current.email))...")
                let backed = claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString)
                log.info("[loginNewAccount] Step 1: Backup result: \(backed)")
            } else {
                log.info("[loginNewAccount] Step 1: No active account, skipping backup")
            }

            // 2. Run `claude auth login` — this overwrites both keychain and ~/.claude.json
            log.info("[loginNewAccount] Step 2: Running `claude auth login`...")
            try await claudeService.login()
            log.info("[loginNewAccount] Step 2: Login process completed")

            // 3. Read the new identity from ~/.claude.json
            log.info("[loginNewAccount] Step 3: Reading post-login state...")
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 3: Not logged in after login!")
                isLoggingIn = false
                return
            }
            guard let identity = keychain.readOAuthIdentity() else {
                errorMessage = String(localized: "Could not read account identity after login", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 3: No oauthAccount identity after login")
                isLoggingIn = false
                return
            }
            let email = identity.emailAddress
            log.info("[loginNewAccount] Step 3: Logged in as \(email)")

            // 4. Check for duplicate — if exists, just refresh its backup
            if let existing = accounts.firstIndex(where: { $0.email == email }) {
                log.info("[loginNewAccount] Step 4: Account already exists, refreshing backup")
                _ = claudeService.captureCurrentCredentials(forAccountId: accounts[existing].id.uuidString)
                errorMessage = String(localized: "Account already exists - credentials refreshed", bundle: L10n.bundle)
                isLoggingIn = false
                return
            }

            // 5. Create new account and capture credentials (token + oauthAccount)
            let account = Account(
                email: email,
                displayName: identity.organizationName ?? email,
                provider: .claudeCode,
                orgName: identity.organizationName,
                subscriptionType: identity.subscriptionTypeLabel,
                isActive: true
            )
            log.info("[loginNewAccount] Step 5: Created account, id=\(account.id)")

            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 5: Capture failed!")
                isLoggingIn = false
                return
            }

            // 6. Mark new account as active
            for i in accounts.indices {
                accounts[i].isActive = false
            }
            accounts.append(account)
            activeAccount = account
            saveAccounts()
            log.info("[loginNewAccount] Step 6: New account active. Total: \(self.accounts.count)")

            isLoggingIn = false
            await refresh()
            log.info("[loginNewAccount] ===== Login completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoggingIn = false
            log.error("[loginNewAccount] Error: \(error.localizedDescription)")
        }
    }

    func updateAccountLabel(_ account: Account, label: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        accounts[index].customLabel = (trimmed?.isEmpty == true) ? nil : trimmed
        if accounts[index].isActive {
            activeAccount = accounts[index]
        }
        saveAccounts()
        updateWidgetData()
        log.info("[updateAccountLabel] Set label for \(account.email): \(trimmed ?? "nil")")
    }

    func removeAccount(_ account: Account) {
        log.info("[removeAccount] Removing account \(account.id)")
        keychain.removeAccountBackup(forAccountId: account.id.uuidString)
        accounts.removeAll { $0.id == account.id }
        if account.isActive, let first = accounts.first {
            accounts[accounts.startIndex].isActive = true
            activeAccount = accounts.first
            log.info("[removeAccount] Removed active account, switching to first remaining")
            Task { await switchTo(first) }
        }
        saveAccounts()
        log.info("[removeAccount] Done. Remaining accounts: \(self.accounts.count)")
    }

    func switchTo(_ account: Account) async {
        // Reentrancy guard via the dedicated `isSwitching` flag (not `isLoading`,
        // which is also set by auto-refresh running every 5min). Using the shared
        // flag would silently drop user clicks during refresh's ~5s window.
        // DeepSeek v2 findings #1 and #3.
        guard !isSwitching else {
            log.info("[switchTo] Skipping: a switch is already in progress")
            return
        }
        guard let currentActive = activeAccount, currentActive.id != account.id else {
            log.info("[switchTo] No switch needed (same account or no active account)")
            return
        }

        log.info("[switchTo] ===== Switching from \(currentActive.email) to \(account.email) =====")

        // Pre-switch: verify target has a backup
        guard keychain.getAccountBackup(forAccountId: account.id.uuidString) != nil else {
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = String(localized: "No stored credentials for \(account.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            return
        }

        isSwitching = true
        defer { isSwitching = false }   // structurally guarantees clear on every exit path
        isLoading = true
        do {
            try await claudeService.switchAccount(from: currentActive, to: account)

            for i in accounts.indices {
                accounts[i].isActive = (accounts[i].id == account.id)
                if accounts[i].id == account.id {
                    accounts[i].lastUsed = Date()
                }
            }
            activeAccount = account
            saveAccounts()

            await refresh()
            log.info("[switchTo] ===== Switch completed =====")
        } catch is CancellationError {
            log.warning("[switchTo] Switch cancelled")
            // Task was cancelled — not an error the user needs to see
        } catch let svcErr as ClaudeServiceError {
            // For probe-detected expired/stale-scope errors, mark the target account
            // as expired so the UI immediately surfaces the "Stale token" badge and
            // the prominent "Re-authenticate" CTA on its row. Without this, the user
            // sees only the errorMessage banner and the misleading "Switch" button stays.
            switch svcErr {
            case .expiredToken, .staleScope:
                accountUsageErrors[account.id] = UsageErrorState(
                    isExpired: true,
                    isRateLimited: false,
                    message: svcErr.errorDescription ?? "Token expired"
                )
            default:
                break
            }
            errorMessage = svcErr.localizedDescription
            isLoading = false
            log.error("[switchTo] Switch failed: \(svcErr.localizedDescription)")
            // D3: rollback ONLY when the failure occurred after Step 3 wrote the
            // keychain. Pre-write failures (staleScope/expired/noToken) left the
            // keychain untouched — "restoring" it would clobber the live token
            // with a possibly-stale backup (the 2026-06-06 logout bug).
            if svcErr.occurredAfterKeychainWrite {
                rollbackKeychain(to: currentActive)
            } else {
                log.info("[switchTo] No rollback — failure occurred before any keychain write (D3)")
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
            // D3: non-ClaudeServiceError throws all originate before Step 3's write
            // (probe/network); the only post-write throws are the enum cases handled
            // above. Never rollback here.
            log.info("[switchTo] No rollback — failure not classified as post-keychain-write (D3)")
        }
    }

    /// Best-effort keychain rollback after a POST-WRITE switch failure (e.g.
    /// Step 4 verify fails, leaving the live keychain holding a broken token).
    /// Without this, the user can be left effectively logged out of Claude Code
    /// until they manually re-auth. DeepSeek v2 finding #2.
    /// D3: callers MUST gate on ClaudeServiceError.occurredAfterKeychainWrite —
    /// invoking this after a pre-write failure writes a stale backup over a live
    /// token (the 2026-06-06 CC-logout bug).
    private func rollbackKeychain(to sourceAccount: Account) {
        guard let backup = keychain.getAccountBackup(forAccountId: sourceAccount.id.uuidString) else { return }
        let tokenOk = keychain.writeClaudeToken(backup.token)
        let oauthOk = keychain.writeOAuthAccount(backup.oauthAccount)
        if tokenOk && oauthOk {
            log.warning("[switchTo] Restored keychain to source account (\(sourceAccount.email)) after switch failure")
        } else {
            // Surface loudly: a failed rollback leaves the live keychain on the broken
            // target token — the user must /login (ltc-reviewer finding 2026-06-06).
            log.error("[switchTo] ROLLBACK FAILED for \(sourceAccount.email) (token=\(tokenOk), oauth=\(oauthOk)) — live keychain may hold a broken token; manual /login required")
            errorMessage = String(localized: "Switch failed AND rollback failed — run /login in a terminal to restore \(sourceAccount.email).", bundle: L10n.bundle)
        }
    }

    /// Re-authenticate an account by running `claude auth login` and capturing fresh credentials.
    func reauthenticateAccount(_ account: Account) async {
        log.info("[reauth] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            return
        }

        isLoggingIn = true
        errorMessage = nil

        do {
            // 1. Back up current active account before login overwrites it
            if let current = activeAccount, current.id != account.id {
                log.info("[reauth] Backing up current account before login...")
                _ = claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString)
            }

            // 2. Run login
            log.info("[reauth] Running `claude auth login`...")
            try await claudeService.login()

            // 3. Verify the login result matches the target account
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                isLoggingIn = false
                return
            }
            guard let identity = keychain.readOAuthIdentity() else {
                errorMessage = String(localized: "Could not read account identity after login", bundle: L10n.bundle)
                isLoggingIn = false
                return
            }
            let email = identity.emailAddress

            guard email == account.email else {
                errorMessage = String(localized: "Logged in as \(email), but expected \(account.email). Credentials not updated.", bundle: L10n.bundle)
                log.error("[reauth] Email mismatch: got \(email), expected \(account.email)")
                isLoggingIn = false
                return
            }

            // 4. Capture the fresh token
            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            log.info("[reauth] Token capture result: \(captured)")

            // 5. Update account metadata
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].orgName = identity.organizationName
                accounts[index].subscriptionType = identity.subscriptionTypeLabel

                // Mark this account as active (it's what the CLI is now using)
                for i in accounts.indices {
                    accounts[i].isActive = (i == index)
                }
                activeAccount = accounts[index]
                saveAccounts()
            }

            isLoggingIn = false
            await refresh()
            log.info("[reauth] ===== Re-authentication completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoggingIn = false
            log.error("[reauth] Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Usage

    /// Proactively refresh INACTIVE accounts' stored tokens that are at or near expiry,
    /// persisting the rotated refresh token each time (ROTATION-SAFETY). Runs every
    /// refresh cycle but only issues a network grant when `expiresAt` is within SKEW —
    /// so at most ~once per token lifetime (~8h), never a tight loop.
    /// D2 (ARCHITECTURE.md §Token Lifecycle): NEVER refresh-grant the ACTIVE account —
    /// refresh tokens are single-use and the CC CLI rotates the active token on its own
    /// clock; a second writer races it and one of them gets invalid_grant (observed live
    /// 2026-06-06 as CC-session logouts). The active account is seeded read-only by the
    /// self-heal in updateActiveAccount instead.
    private func refreshExpiringTokens() async {
        let skewMillis = 10.0 * 60 * 1000   // refresh when within 10 min of expiry
        let nowMillis = Date().timeIntervalSince1970 * 1000
        for account in accounts {
            if account.isActive {
                log.debug("[proactiveRefresh] skipping active \(account.email) (D2 — CLI owns its rotation)")
                continue
            }
            guard let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString),
                  let expiresAt = ClaudeService.extractExpiresAt(from: backup.token),
                  let refreshTok = ClaudeService.extractRefreshToken(from: backup.token) else {
                continue
            }
            guard expiresAt - nowMillis <= skewMillis else { continue }   // still fresh — skip
            guard !refreshingAccounts.contains(account.id) else { continue }  // grant already in flight
            refreshingAccounts.insert(account.id)
            defer { refreshingAccounts.remove(account.id) }
            do {
                let creds = try await claudeService.refresher.refresh(refreshToken: refreshTok)
                let ok = keychain.persistRefreshedCreds(creds, forAccountId: account.id.uuidString, isActive: account.isActive)
                log.info("[proactiveRefresh] \(account.email): refreshed, persisted=\(ok)")
            } catch {
                // Non-fatal: a dead refresh token surfaces as the usual expired-state in
                // fetchAllAccountUsage / on switch. Don't block the refresh cycle.
                log.warning("[proactiveRefresh] \(account.email): refresh failed — \(error.localizedDescription)")
            }
        }
    }

    /// On a usage 401, recover and retry usage ONCE. Returns true on recovery.
    /// ACTIVE account (D2): NEVER refresh-grant — the CC CLI owns the active token's
    /// rotation and has likely already refreshed it; re-read the keychain and retry
    /// with whatever the CLI minted. Refresh-granting here would consume the CLI's
    /// single-use refresh token and log the user's CC session out.
    /// INACTIVE accounts: direct refresh-grant against the backup store (no keychain
    /// write — no race with the CLI), persist rotated creds (ROTATION-SAFETY), retry.
    private func refreshAndRetryUsage(account: Account) async -> Bool {
        if account.isActive {
            guard let tokenJSON = keychain.readClaudeToken(),
                  let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
                return false
            }
            do {
                let usage = try await claudeService.getUsageLimits(accessToken: accessToken)
                accountUsage[account.id] = usage
                accountUsageErrors[account.id] = nil
                log.info("[fetchUsage] Recovered \(account.email) via keychain re-read (D2).")
                return true
            } catch {
                log.error("[fetchUsage] Keychain re-read retry failed for \(account.email): \(error.localizedDescription)")
                return false
            }
        }
        guard let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString),
              let refreshTok = ClaudeService.extractRefreshToken(from: backup.token) else {
            return false
        }
        guard !refreshingAccounts.contains(account.id) else { return false }  // grant already in flight
        refreshingAccounts.insert(account.id)
        defer { refreshingAccounts.remove(account.id) }
        do {
            let creds = try await claudeService.refresher.refresh(refreshToken: refreshTok)
            guard keychain.persistRefreshedCreds(creds, forAccountId: account.id.uuidString, isActive: account.isActive) else {
                return false
            }
            let usage = try await claudeService.getUsageLimits(accessToken: creds.accessToken)
            accountUsage[account.id] = usage
            accountUsageErrors[account.id] = nil
            log.info("[fetchUsage] Recovered \(account.email) via direct refresh.")
            return true
        } catch {
            log.error("[fetchUsage] Direct refresh failed for \(account.email): \(error.localizedDescription)")
            return false
        }
    }

    private func fetchAllAccountUsage() async {
        accountUsageErrors.removeAll()
        // For active account: use live keychain token (with delegated refresh on expiry)
        // For other accounts: use backup token (no silent swap — just mark expired)
        for account in accounts {
            let tokenJSON: String?
            if account.isActive {
                tokenJSON = keychain.readClaudeToken()
            } else {
                tokenJSON = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
            }
            guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
                log.warning("[fetchUsage] No token for \(account.email), skipping")
                continue
            }
            do {
                let usage = try await claudeService.getUsageLimits(accessToken: accessToken)
                accountUsage[account.id] = usage
                accountUsageErrors[account.id] = nil
                log.info("[fetchUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
            } catch ClaudeService.UsageError.expired {
                // Direct refresh-grant + retry, for BOTH active and inactive accounts.
                // Persisting to the backup store (and keychain only when active) is safe —
                // no silent keychain swap for inactive accounts, so no race with the CLI.
                log.warning("[fetchUsage] Token expired for \(account.email) — attempting direct refresh")
                let recovered = await refreshAndRetryUsage(account: account)
                if !recovered {
                    accountUsage[account.id] = nil
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Token expired. Re-authenticate to fix.", bundle: L10n.bundle))
                }
            } catch {
                log.error("[fetchUsage] Failed to get usage for \(account.email): \(error.localizedDescription)")
                accountUsage[account.id] = nil
                if let usageError = error as? ClaudeService.UsageError, case .network(let msg) = usageError, msg.contains("429") {
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: true, message: String(localized: "API Rate Limited. Try again later.", bundle: L10n.bundle))
                } else {
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Could not fetch usage: \(error.localizedDescription)", bundle: L10n.bundle))
                }
            }
        }
    }

    // MARK: - Diagnostics

    /// Passive health check — verifies backup existence and identity consistency.
    private func diagnoseTokenHealth() {
        guard !accounts.isEmpty else { return }

        log.info("[diagnose] === Health Check ===")
        log.info("[diagnose] Accounts: \(self.accounts.count), active: \(self.activeAccount?.email ?? "none")")

        // Check live oauthAccount identity
        if let liveOAuth = keychain.readOAuthAccount() {
            let liveEmail = (liveOAuth["emailAddress"]?.value as? String) ?? "?"
            log.info("[diagnose] Live oauthAccount: \(liveEmail)")
        } else {
            log.warning("[diagnose] Live oauthAccount: MISSING")
        }

        // Check each account has a backup
        for account in accounts {
            if let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString) {
                let backupEmail = (backup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
                log.info("[diagnose] Backup [\(account.email)]: OK (email=\(backupEmail))")
            } else {
                log.warning("[diagnose] Backup [\(account.email)]: MISSING — switch will fail")
            }
        }

        log.info("[diagnose] === End Health Check ===")
    }

    // MARK: - Widget

    private func updateWidgetData() {
        let widgetAccounts = accounts.map { account in
            let usage = accountUsage[account.id]
            let error = accountUsageErrors[account.id]
            return WidgetAccountData(
                email: account.displayEmail(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                displayName: account.effectiveDisplayName(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                subscriptionType: account.displaySubscriptionType,
                isActive: account.isActive,
                sessionUtilization: usage?.fiveHour?.utilization,
                sessionResetTime: usage?.fiveHour?.resetTimeString,
                weeklyUtilization: usage?.sevenDay?.utilization,
                weeklyResetTime: usage?.sevenDay?.resetTimeString,
                extraUsageEnabled: usage?.extraUsage?.isEnabled,
                hasError: error != nil,
                errorMessage: error?.message
            )
        }

        let data = WidgetData(
            accounts: widgetAccounts,
            todayCost: costSummary.todayCost,
            conversationTurns: activityStats.conversationTurns,
            activeCodingTime: activityStats.activeCodingTimeString,
            linesWritten: activityStats.linesWritten,
            modelUsage: activityStats.modelUsage,
            lastUpdated: Date()
        )
        data.save()
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("[updateWidgetData] Widget data saved and timelines reloaded")
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            log.info("[loadAccounts] No saved accounts found")
            return
        }
        accounts = decoded
        activeAccount = accounts.first(where: \.isActive)
        log.info("[loadAccounts] Loaded \(decoded.count) accounts")
    }

    private func saveAccounts(refreshWidget: Bool = false) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
            log.debug("[saveAccounts] Saved \(self.accounts.count) accounts to UserDefaults")
        }
        if refreshWidget {
            updateWidgetData()
        }
    }

    private func updateActiveAccount(from status: AuthStatus) {
        guard status.loggedIn else { return }
        guard let identity = keychain.readOAuthIdentity() else {
            log.warning("[updateActiveAccount] No oauthAccount identity in ~/.claude.json")
            return
        }
        let email = identity.emailAddress

        if let index = accounts.firstIndex(where: { $0.email == email }) {
            for i in accounts.indices {
                accounts[i].isActive = (i == index)
            }
            accounts[index].orgName = identity.organizationName
            accounts[index].subscriptionType = identity.subscriptionTypeLabel
            activeAccount = accounts[index]
            saveAccounts()
            log.info("[updateActiveAccount] Matched existing account at index \(index)")

            // SELF-HEAL (ARCHITECTURE.md §Seeding invariant): an external re-auth
            // (CLI `/login`) rotates the live keychain token WITHOUT going through the
            // in-app reauth flow, leaving the backup-store snapshot holding a dead
            // refresh token that proactiveRefresh then flogs forever. Whenever the
            // live token differs from this account's backup, re-snapshot it.
            // Idempotent: string-equal tokens skip; capture re-reads live keychain.
            // Under D1, readClaudeToken() reads the keychain directly — no mirror to go stale.
            let accountId = accounts[index].id.uuidString
            if let liveToken = keychain.readClaudeToken(),
               keychain.getAccountBackup(forAccountId: accountId)?.token != liveToken {
                let captured = claudeService.captureCurrentCredentials(forAccountId: accountId)
                log.info("[updateActiveAccount] Live token differs from backup — re-captured: \(captured)")
            }
        } else if accounts.isEmpty {
            let account = Account(
                email: email,
                displayName: identity.organizationName ?? email,
                provider: .claudeCode,
                orgName: identity.organizationName,
                subscriptionType: identity.subscriptionTypeLabel,
                isActive: true
            )
            accounts.append(account)
            activeAccount = account
            _ = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            saveAccounts()
            log.info("[updateActiveAccount] Auto-created first account, id=\(account.id)")
        } else {
            log.info("[updateActiveAccount] Logged-in account not in our list (might be new)")
        }
    }
}
