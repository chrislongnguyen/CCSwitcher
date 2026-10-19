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
    /// When each account's usage sample was actually taken. Accounts are polled
    /// round-robin (active + one other per cycle), so a card can be showing a
    /// reading several cycles old; without this the UI would render a stale
    /// percentage exactly like a live one, and auto-switch could not tell
    /// which samples this cycle actually verified.
    @Published var accountUsageSampledAt: [UUID: Date] = [:]
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

    // MARK: - Usage polling state

    /// Re-entrancy guard: overlapping refreshes (timer + manual button + post-switch)
    /// would each burst per-account usage requests and trip the endpoint's rate limit.
    private var isRefreshing = false

    /// Round-robin cursor over non-active accounts: each refresh cycle fetches usage
    /// for the active account plus ONE other, instead of all of them. The usage
    /// endpoint's rate limit is tight and shared with every running Claude Code
    /// session's own polling, so fewer requests per cycle beats a full sweep.
    private var usageFetchCursor = 0

    /// Per-account "leave it alone until" timestamps. The usage endpoint enforces a
    /// long-window per-account quota - observed Retry-After values run into tens of
    /// minutes - so once an account is rate-limited, polling it again before the
    /// server-given deadline just burns more quota. Stale samples are kept meanwhile.
    private var usageRetryNotBefore: [UUID: Date] = [:]

    /// When the current/most recent refresh cycle began. Auto-switch uses it to
    /// tell which usage samples were taken by THIS cycle (already fresh — no
    /// verification request needed) versus retained from earlier ones.
    private var lastCycleStart: Date = .distantPast

    /// One switch (manual or automatic) may mutate live credentials at a time.
    /// `switchTo` suspends across subprocess and keychain work while the UI stays
    /// responsive, so without this a second switch — a user click during an
    /// auto-switch verification, or vice versa — could interleave keychain and
    /// ~/.claude.json writes with the first.
    private var isSwitching = false

    // MARK: - Auto-switch

    /// Whether proactive auto-switch is on (written by SettingsView via @AppStorage).
    private var autoSwitchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoSwitchEnabled")
    }

    /// Utilization percentage at which we switch. Defaults to 90 when unset.
    private var autoSwitchThreshold: Double {
        let stored = UserDefaults.standard.double(forKey: "autoSwitchThreshold")
        return stored == 0 ? 90 : stored
    }

    /// A candidate must sit at least this far below the threshold to be eligible,
    /// so two accounts hovering at the line never ping-pong.
    private let autoSwitchHysteresis: Double = 10

    /// Minimum gap between two automatic switches, to avoid rapid flip-flopping.
    private let autoSwitchCooldown: TimeInterval = 300

    private var lastAutoSwitchAt: Date?
    private var isEvaluatingAutoSwitch = false

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

    /// Refresh everything, then decide whether to auto-switch.
    ///
    /// The two halves are deliberately separate: `refreshData()` holds the
    /// `isRefreshing` re-entrancy guard for its whole body, so evaluating
    /// auto-switch *inside* it would mean the `switchTo() -> refresh()` that
    /// follows an automatic switch gets swallowed by that guard — leaving the
    /// spinner stuck and the new active account showing pre-switch numbers.
    /// And when `refreshData()` did NOT run (login in progress, another refresh
    /// already running), auto-switch must not be evaluated either: it would act
    /// on state mid-mutation — swapping credentials during a login, or deciding
    /// on samples a concurrent refresh is rewriting.
    func refresh() async {
        guard await refreshData() else { return }
        await evaluateAutoSwitch()
    }

    /// Returns true only when a full refresh actually ran.
    private func refreshData() async -> Bool {
        guard !isLoggingIn else {
            log.info("[refresh] Skipping: login in progress")
            return false
        }
        guard !isRefreshing else {
            log.info("[refresh] Skipping: refresh already in progress")
            return false
        }
        isRefreshing = true
        defer { isRefreshing = false }
        lastCycleStart = Date()
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
        await SessionParseCacheV2.shared.refreshFromFilesystem()
        let cost = await costParser.getCostSummary()
        let activity = await activityParser.getTodayStats()
        costSummary = cost
        activityStats = activity

        log.info("[refresh] Usage: weekly=\(self.usageSummary.weeklyMessages) msgs, \(self.activeSessions.count) active sessions, today=$\(String(format: "%.2f", cost.todayCost)) turns=\(activity.conversationTurns)")

        updateWidgetData()
        isLoading = false
        return true
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
        // One credential mutation at a time (same guard as switchTo). A login
        // entering while a switch is suspended mid-swap would back up the
        // WRONG live credential under the old active account's id — quietly
        // destroying that account's usable backup. Also blocks double-clicks.
        guard !isSwitching, !isLoggingIn else {
            log.warning("[loginNewAccount] Skipped: a switch or another login is in progress")
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

            // 4. Check for duplicate — if exists, refresh its backup and make it
            // the active account. The login DID change what the CLI is
            // authenticated as; returning without updating our model left the
            // menu bar and switcher presenting an account the CLI was no longer
            // using. The capture CAN also fail (e.g. the backup store refuses
            // writes while unreadable); claiming "credentials refreshed" then
            // would leave a stale backup behind an explicit success message.
            if let existing = accounts.firstIndex(where: { $0.email == email }) {
                log.info("[loginNewAccount] Step 4: Account already exists, refreshing backup and marking it active")
                let captured = claudeService.captureCurrentCredentials(forAccountId: accounts[existing].id.uuidString)
                for i in accounts.indices {
                    accounts[i].isActive = (i == existing)
                }
                accounts[existing].lastUsed = Date()
                activeAccount = accounts[existing]
                // A login is a deliberate account choice; grant it the same
                // auto-switch grace period a manual switch gets.
                lastAutoSwitchAt = Date()
                saveAccounts()
                if captured {
                    errorMessage = String(localized: "Account already exists - credentials refreshed", bundle: L10n.bundle)
                } else {
                    log.error("[loginNewAccount] Step 4: Backup capture FAILED for existing account")
                    errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                }
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
            // A login is a deliberate account choice; grant it the same
            // auto-switch grace period a manual switch gets.
            lastAutoSwitchAt = Date()
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
        // Drop every per-account cache too, or a re-added account inherits the
        // removed one's readings, error banner and rate-limit park.
        accountUsage[account.id] = nil
        accountUsageSampledAt[account.id] = nil
        accountUsageErrors[account.id] = nil
        usageRetryNotBefore[account.id] = nil
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
        guard let currentActive = activeAccount, currentActive.id != account.id else {
            log.info("[switchTo] No switch needed (same account or no active account)")
            return
        }

        log.info("[switchTo] ===== Switching from \(currentActive.email) to \(account.email) =====")

        // One credential mutation at a time, via the dedicated `isSwitching` flag
        // (not `isLoading`, which auto-refresh also sets — sharing it would drop
        // user clicks during a refresh; DeepSeek v2 findings #1 and #3). A switch
        // already in flight (its awaits leave the main actor free) or a running
        // login must finish before another switch may touch the keychain and
        // ~/.claude.json.
        guard !isSwitching, !isLoggingIn else {
            log.warning("[switchTo] Skipped: another switch or a login is in progress")
            return
        }
        isSwitching = true
        defer { isSwitching = false }

        // Pre-switch: resolve the target's backup ONCE and hand it down.
        // "The store is briefly unreadable" and "no backup exists" are
        // different problems with different fixes — don't send the user to
        // re-authenticate over a locked keychain. Passing the resolved backup
        // into switchAccount also removes its second lookup, which collapsed
        // exactly this distinction one layer down.
        let targetBackup: AccountBackup
        switch keychain.lookupAccountBackup(forAccountId: account.id.uuidString) {
        case .found(let backup):
            targetBackup = backup
        case .missing:
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = String(localized: "No stored credentials for \(account.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            return
        case .storeUnavailable:
            log.error("[switchTo] ABORT: backup store unreadable right now")
            errorMessage = String(localized: "Credential storage is temporarily unavailable. Try again shortly.", bundle: L10n.bundle)
            return
        }

        // Any switch, deliberate or automatic, restarts the auto-switch cooldown:
        // a user who knowingly picks an account sitting at 95% must not be
        // auto-switched away from it seconds later by the refresh that follows.
        lastAutoSwitchAt = Date()

        isLoading = true
        do {
            let outcome = try await claudeService.switchAccount(from: currentActive, to: account, targetBackup: targetBackup)

            for i in accounts.indices {
                accounts[i].isActive = (accounts[i].id == account.id)
                if accounts[i].id == account.id {
                    accounts[i].lastUsed = Date()
                }
            }
            activeAccount = account
            saveAccounts()

            await refresh()
            // `refresh()` clears errorMessage, so surface the warning afterwards.
            if let shadowedBy = outcome.shadowedBy {
                errorMessage = String(localized: "Switched to \(account.email), but the Claude CLI is authenticating via \(shadowedBy) instead of the stored login, so it will not use this account.", bundle: L10n.bundle)
            }
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

    // MARK: - Auto-switch

    /// Whether an account can be switched to right now: it must have a stored
    /// backup token and not be flagged expired (an expired backup would fail the
    /// switch verification, or silently swap in a dead session).
    private func isSwitchable(_ account: Account) -> Bool {
        guard keychain.getAccountBackup(forAccountId: account.id.uuidString) != nil else { return false }
        if let error = accountUsageErrors[account.id], error.isExpired { return false }
        return true
    }

    /// Evaluate whether the active account has reached the threshold and, if so,
    /// switch to the same-provider account with the most quota left.
    /// Called after every completed refresh. Safe to call repeatedly.
    ///
    /// Candidates are ranked from whatever samples we hold, then the chosen one
    /// is VERIFIED before committing: round-robin polling can leave a candidate's
    /// sample several cycles old, and quota may have been consumed on it from
    /// another device meanwhile. A sample taken by this very cycle counts as
    /// verified; otherwise one fresh reading is taken — a single request per
    /// (rare, threshold-gated, cooldown-gated) switch attempt, not the per-cycle
    /// burst the round-robin exists to prevent.
    private func evaluateAutoSwitch() async {
        guard autoSwitchEnabled, !isEvaluatingAutoSwitch else { return }
        guard !isLoggingIn, !isSwitching, let active = activeAccount else { return }

        // Cooldown: never auto-switch more than once per window.
        if let last = lastAutoSwitchAt, Date().timeIntervalSince(last) < autoSwitchCooldown {
            return
        }

        // Only consider same-provider accounts (a Claude switch never touches Codex/Gemini).
        let candidates = accounts.filter { $0.provider == active.provider && $0.id != active.id }
        let activeSampledThisCycle = (accountUsageSampledAt[active.id] ?? .distantPast) >= lastCycleStart
        let ranked = AutoSwitchEngine.rankedTargets(
            active: active,
            candidates: candidates,
            usageByAccount: accountUsage,
            isSwitchable: { [unowned self] in self.isSwitchable($0) },
            activeSampledThisCycle: activeSampledThisCycle,
            threshold: autoSwitchThreshold,
            hysteresisPct: autoSwitchHysteresis
        )
        guard !ranked.isEmpty else { return }

        isEvaluatingAutoSwitch = true
        defer { isEvaluatingAutoSwitch = false }

        let activeUtil = AutoSwitchEngine.bindingUtilization(accountUsage[active.id]) ?? -1
        let ceiling = autoSwitchThreshold - autoSwitchHysteresis
        log.info("[autoSwitch] Active \(active.id) at \(String(format: "%.0f", activeUtil))% (threshold \(String(format: "%.0f", self.autoSwitchThreshold))%); \(ranked.count) candidate(s)")

        // At most ONE fresh verification request per evaluation. Later ranked
        // candidates only qualify via samples this cycle already took.
        var freshRequestBudget = 1
        for target in ranked {
            let usage: UsageAPIResponse?
            if let sampledAt = accountUsageSampledAt[target.id], sampledAt >= lastCycleStart {
                // Sampled by this very cycle — that IS a fresh reading.
                usage = accountUsage[target.id]
            } else if freshRequestBudget > 0 {
                freshRequestBudget -= 1
                usage = await fetchUsageNow(for: target)
                if let usage {
                    accountUsage[target.id] = usage
                    accountUsageSampledAt[target.id] = Date()
                    accountUsageErrors[target.id] = nil
                }
            } else {
                continue
            }

            guard let verifiedUtil = AutoSwitchEngine.bindingUtilization(usage),
                  verifiedUtil <= ceiling else {
                log.info("[autoSwitch] Candidate \(target.id) failed verification (\(AutoSwitchEngine.bindingUtilization(usage).map { String(format: "%.0f%%", $0) } ?? "no reading")); trying next")
                continue
            }

            // Re-check volatile state: the verification await above can span a
            // login starting, a timer-tick refresh beginning, or a manual switch
            // the user just clicked (which updates `activeAccount` only after
            // its subprocess work finishes — hence the explicit isSwitching).
            guard !isLoggingIn, !isRefreshing, !isSwitching, activeAccount?.id == active.id else {
                log.info("[autoSwitch] State changed during verification; standing down")
                return
            }

            log.info("[autoSwitch] Switching to \(target.id), verified at \(String(format: "%.0f", verifiedUtil))%")
            lastAutoSwitchAt = Date()
            // switchTo() calls refresh() -> evaluateAutoSwitch() again, but the
            // re-entrancy flag + the freshly-set cooldown make that a no-op.
            // The active account visibly changes in the menu bar as feedback.
            await switchTo(target)
            return
        }
        log.info("[autoSwitch] Threshold reached but no candidate verified; staying put")
    }

    /// Take one fresh usage reading for an account right now, refreshing its
    /// stored credential in place first if the access token has expired.
    /// Returns nil when no reading could be taken. 429s are parked with the same
    /// scheme the polling loop uses, so verification can never leak around it.
    private func fetchUsageNow(for account: Account) async -> UsageAPIResponse? {
        if let notBefore = usageRetryNotBefore[account.id], notBefore > Date() {
            log.info("[fetchUsageNow] \(account.id) is rate-limit parked; no fresh reading available")
            return nil
        }

        let tokenJSON = account.isActive
            ? keychain.readClaudeToken()
            : keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
        guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
            return nil
        }

        do {
            return try await claudeService.getUsageLimits(accessToken: accessToken)
        } catch ClaudeService.UsageError.expired where !account.isActive {
            // Handle every refresh outcome, not just success: collapsing a dead
            // grant (or a lost rotation) to a plain nil here would leave the
            // account looking healthy — stale usage still shown, still eligible
            // for auto-switch — until a later polling pass happened to notice.
            switch await refreshBackupInPlace(for: account) {
            case .refreshed(let refreshed):
                guard let newToken = ClaudeService.extractAccessToken(from: refreshed) else { return nil }
                return await usageRespectingParking(accessToken: newToken, account: account)
            case .grantRejected, .noBackup, .rotationLost:
                accountUsage[account.id] = nil
                accountUsageSampledAt[account.id] = nil
                accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Session expired. Re-authenticate (↻) to fix.", bundle: L10n.bundle))
                return nil
            case .storeUnavailable:
                // Nothing spent, nothing lost; keep the stale sample and retry
                // on a later cycle.
                return nil
            }
        } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
            park(account, retryAfter: retryAfter)
            return nil
        } catch {
            log.warning("[fetchUsageNow] \(account.id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Re-authenticate an account by running `claude auth login` and capturing fresh credentials.
    func reauthenticateAccount(_ account: Account) async {
        log.info("[reauth] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            return
        }
        // One credential mutation at a time — see loginNewAccount for why a
        // login during a suspended switch destroys a backup.
        guard !isSwitching, !isLoggingIn else {
            log.warning("[reauth] Skipped: a switch or another login is in progress")
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

            // 5. Update account metadata. Done even when the capture failed —
            // the CLI really is on this account now — but a failed capture must
            // be surfaced, not folded into "completed": the stored backup is
            // still the OLD credential, so a later switch away and back would
            // fail while the UI claimed everything was refreshed.
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].orgName = identity.organizationName
                accounts[index].subscriptionType = identity.subscriptionTypeLabel

                // Mark this account as active (it's what the CLI is now using)
                for i in accounts.indices {
                    accounts[i].isActive = (i == index)
                }
                activeAccount = accounts[index]
                // A re-authentication is a deliberate account choice; grant it
                // the same auto-switch grace period a manual switch gets.
                lastAutoSwitchAt = Date()
                saveAccounts()
            }

            isLoggingIn = false
            await refresh()
            if captured {
                log.info("[reauth] ===== Re-authentication completed =====")
            } else {
                // Set AFTER refresh() — refresh clears errorMessage.
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[reauth] ===== Re-authentication finished, but the backup capture FAILED =====")
            }
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
                  let expiresAt = ClaudeService.extractExpiresAt(from: backup.token) else {
                continue
            }
            guard expiresAt - nowMillis <= skewMillis else { continue }   // still fresh — skip
            // Non-fatal whatever the outcome: a dead refresh token surfaces as the usual
            // expired state in fetchAllAccountUsage / on switch.
            let outcome = await refreshBackupInPlace(for: account)
            log.info("[proactiveRefresh] \(account.email): \(outcome)")
        }
    }

    /// Fetch usage with a single retry on 429 - but only when Retry-After is short.
    /// Observed Retry-After values run into tens of minutes (long-window per-account
    /// quota); retrying against those just burns more quota, so we rethrow instead
    /// and let the caller park the account until the deadline.
    private func fetchUsageWithRetry(accessToken: String) async throws -> UsageAPIResponse {
        do {
            return try await claudeService.getUsageLimits(accessToken: accessToken)
        } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
            let delay = retryAfter ?? 15
            guard delay <= 30 else {
                throw ClaudeService.UsageError.rateLimited(retryAfter: retryAfter)
            }
            // Floor of 3s: "Retry-After: 0" is a momentary burst limiter, and an
            // immediate (~1s) retry was observed to fail again.
            log.warning("[fetchUsage] Rate-limited, retrying in \(String(format: "%.0f", max(delay, 3)))s...")
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 3) * 1_000_000_000))
            return try await claudeService.getUsageLimits(accessToken: accessToken)
        }
    }

    /// Park an account until the server-given deadline (floor 60s — "Retry-After:
    /// 0" burst rejections must still park; cap 1h; default 2min when no
    /// Retry-After was sent). Every path that observes a 429 goes through here.
    private func park(_ account: Account, retryAfter: TimeInterval?) {
        let parkFor = min(max(retryAfter ?? 120, 60), 3600)
        usageRetryNotBefore[account.id] = Date().addingTimeInterval(parkFor)
        log.warning("[fetchUsage] \(account.id) rate-limited; parked for \(String(format: "%.0f", parkFor))s")
    }

    /// Fetch usage, honouring a 429 by parking the account. The post-refresh
    /// recovery paths previously wrapped this call in `try?`, which swallowed a
    /// 429 without parking it — leaking around the parking scheme and re-hitting
    /// a rate-limited account every cycle.
    private func usageRespectingParking(accessToken: String, account: Account) async -> UsageAPIResponse? {
        do {
            return try await claudeService.getUsageLimits(accessToken: accessToken)
        } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
            park(account, retryAfter: retryAfter)
            return nil
        } catch {
            log.warning("[fetchUsage] Post-refresh retry failed for \(account.id): \(error.localizedDescription)")
            return nil
        }
    }

    private enum BackupRefreshOutcome {
        /// New credential JSON, persisted to the store.
        case refreshed(String)
        /// The endpoint decided the grant is invalid: the refresh token is dead
        /// (rotated elsewhere or revoked). Only re-authentication fixes this.
        case grantRejected
        /// No stored backup exists for this account at all.
        case noBackup
        /// Nothing was spent and nothing is lost: the store cannot be read or
        /// written right now, the refresh attempt failed transiently (network,
        /// server error, edge block), or a grant for this account is already in
        /// flight. Heals by itself on a later cycle.
        case storeUnavailable
        /// Worst case: the rotation succeeded but the result could not be
        /// persisted even after a retry. The old refresh token is spent and the
        /// new credential is gone — only re-authentication brings this account
        /// back. Deliberately NOT held in memory: a credential that exists only
        /// in volatile state while some paths read the (dead) stored one is the
        /// split-brain that broke the previous attempt at this feature.
        case rotationLost
    }

    /// The ONE app-side refresh path for stored credentials (proactive and reactive).
    /// Refreshes a NON-ACTIVE account's backup in place via `claudeService.refresher`
    /// (Option A, ARCHITECTURE.md §Token Lifecycle) and persists the rotated token
    /// through `persistRefreshedCreds` — backup store only, never the live keychain,
    /// so there is no race with running Claude Code sessions.
    private func refreshBackupInPlace(for account: Account) async -> BackupRefreshOutcome {
        let accountId = account.id.uuidString

        // D2: the CC CLI owns the active account's rotation.
        guard !account.isActive else {
            log.error("[refreshBackup] Refused for active account \(account.id) (D2)")
            return .storeUnavailable
        }

        let backup: AccountBackup
        switch keychain.lookupAccountBackup(forAccountId: accountId) {
        case .found(let found):
            backup = found
        case .missing:
            log.warning("[refreshBackup] No stored backup for \(account.id)")
            return .noBackup
        case .storeUnavailable:
            log.warning("[refreshBackup] Store unreadable for \(account.id); trying again next cycle")
            return .storeUnavailable
        }

        guard let refreshTok = ClaudeService.extractRefreshToken(from: backup.token) else {
            log.warning("[refreshBackup] Stored credential for \(account.id) has no refresh token")
            return .grantRejected
        }

        // Refresh tokens are single-use: two concurrent grants for the same account
        // would make the second fail with invalid_grant on a token the first already
        // rotated away. Reviewer Finding #2.
        guard !refreshingAccounts.contains(account.id) else {
            log.info("[refreshBackup] Grant already in flight for \(account.id)")
            return .storeUnavailable
        }
        refreshingAccounts.insert(account.id)
        defer { refreshingAccounts.remove(account.id) }

        // Prove the store is writable BEFORE spending the refresh token: the
        // endpoint rotates it, and a rotation that cannot be persisted kills the
        // account (old token dead server-side, new one lost, manual re-login the
        // only way back). Re-saving what was just read is idempotent.
        guard keychain.saveAccountBackup(token: backup.token, oauthAccount: backup.oauthAccount, forAccountId: accountId) else {
            log.error("[refreshBackup] Store not writable; skipping refresh for \(account.id) so its refresh token stays valid")
            return .storeUnavailable
        }

        do {
            let creds = try await claudeService.refresher.refresh(refreshToken: refreshTok)
            // ROTATION-SAFETY: persist before anything else uses the new token.
            for attempt in 1...2 {
                if keychain.persistRefreshedCreds(creds, forAccountId: accountId, isActive: false),
                   let refreshed = keychain.getAccountBackup(forAccountId: accountId) {
                    return .refreshed(refreshed.token)
                }
                if attempt == 1 {
                    // The probe passed moments ago, so this is likely a blip — one retry.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            log.error("[refreshBackup] Rotation succeeded but the store write failed twice for \(account.id); the account needs re-authentication")
            return .rotationLost
        } catch let err as TokenRefreshError {
            switch err {
            case .noRefreshToken, .invalidGrant:
                log.warning("[refreshBackup] Refresh grant rejected for \(account.id); the refresh token is dead")
                return .grantRejected
            case .edgeBlocked, .network, .decode:
                log.warning("[refreshBackup] Refresh attempt for \(account.id) failed transiently (\(err.localizedDescription)); will retry")
                return .storeUnavailable
            }
        } catch {
            log.warning("[refreshBackup] Refresh attempt for \(account.id) failed: \(error.localizedDescription); will retry")
            return .storeUnavailable
        }
    }

    private func fetchAllAccountUsage() async {
        // Pick this cycle's targets: the active account (always) + one non-active
        // account in round-robin order. Stale samples for the others are kept.
        // Accounts parked by a server-given Retry-After deadline are skipped.
        let now = Date()
        let eligible = accounts.filter { (usageRetryNotBefore[$0.id] ?? .distantPast) <= now }
        let others = eligible.filter { !$0.isActive }
        var targets = eligible.filter { $0.isActive }
        if !others.isEmpty {
            targets.append(others[usageFetchCursor % others.count])
            usageFetchCursor += 1
        }

        // Only clear error state for the accounts we are about to sample;
        // the others keep both their stale usage and their error flags.
        for target in targets {
            accountUsageErrors[target.id] = nil
        }

        // For active account: use live keychain token (with delegated refresh on expiry)
        // For other accounts: use backup token (refreshed in place when expired)
        var isFirstRequest = true
        for account in targets {
            // Stagger requests: a back-to-back burst (one request per account within
            // ~100ms) reliably gets all but one of them 429'd by the usage endpoint.
            if !isFirstRequest {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            isFirstRequest = false

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
                let usage = try await fetchUsageWithRetry(accessToken: accessToken)
                accountUsage[account.id] = usage
                accountUsageSampledAt[account.id] = Date()
                accountUsageErrors[account.id] = nil
                log.info("[fetchUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
            } catch ClaudeService.UsageError.forbidden {
                // No active Pro/Max subscription on this account (e.g. the plan
                // lapsed) - usage is meaningless until it recovers. Observed as:
                // {"error":{"type":"permission_error","message":"OAuth
                // authentication is currently not allowed for this organization."}}
                log.warning("[fetchUsage] \(account.email) forbidden (no active subscription?)")
                accountUsage[account.id] = nil
                accountUsageSampledAt[account.id] = nil
                accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "No active subscription on this account (OAuth not allowed).", bundle: L10n.bundle))
            } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
                // Rate-limited: park the account until the server-given deadline
                // and keep the last known sample - a stale percentage carrying
                // its "Updated Xm ago" label beats an error banner. The sample
                // timestamp is deliberately NOT bumped, so the UI keeps telling
                // the truth about how old the number is.
                park(account, retryAfter: retryAfter)
                if accountUsage[account.id] == nil {
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: true, message: String(localized: "API Rate Limited. Try again later.", bundle: L10n.bundle))
                }
            } catch ClaudeService.UsageError.expired {
                log.warning("[fetchUsage] Token expired for \(account.email)")
                if account.isActive {
                    // D2: NEVER refresh-grant the active account — the CC CLI owns its
                    // rotation and has likely already refreshed it. Re-read the keychain
                    // and retry ONCE with whatever the CLI minted. No `claude auth status`
                    // spawn here (popup-free hot path).
                    if let refreshedJSON = keychain.readClaudeToken(),
                       let refreshedToken = ClaudeService.extractAccessToken(from: refreshedJSON),
                       refreshedToken != accessToken {
                        do {
                            let usage = try await claudeService.getUsageLimits(accessToken: refreshedToken)
                            accountUsage[account.id] = usage
                            accountUsageSampledAt[account.id] = Date()
                            accountUsageErrors[account.id] = nil
                            log.info("[fetchUsage] Recovered \(account.email) via keychain re-read (D2).")
                        } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
                            park(account, retryAfter: retryAfter)
                        } catch {
                            log.error("[fetchUsage] Keychain re-read retry failed for \(account.email): \(error.localizedDescription)")
                            accountUsage[account.id] = nil
                            accountUsageSampledAt[account.id] = nil
                            accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Token expired. Re-authenticate to fix.", bundle: L10n.bundle))
                        }
                    } else {
                        log.warning("[fetchUsage] Active keychain token unchanged since the 401 — waiting for the CLI to rotate it")
                        accountUsage[account.id] = nil
                        accountUsageSampledAt[account.id] = nil
                        accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Token expired. Re-authenticate to fix.", bundle: L10n.bundle))
                    }
                } else {
                    // Non-active account: refresh the backup credential in place —
                    // no keychain swap, so no race with running Claude Code sessions.
                    switch await refreshBackupInPlace(for: account) {
                    case .refreshed(let refreshed):
                        log.info("[fetchUsage] Silently refreshed backup for \(account.email); retrying usage")
                        if let newToken = ClaudeService.extractAccessToken(from: refreshed),
                           let usage = await usageRespectingParking(accessToken: newToken, account: account) {
                            accountUsage[account.id] = usage
                            accountUsageSampledAt[account.id] = Date()
                            accountUsageErrors[account.id] = nil
                            log.info("[fetchUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
                        }
                    case .grantRejected, .noBackup, .rotationLost:
                        // Only re-authentication mints a new refresh token or a
                        // new backup — an honest dead end until the user acts.
                        accountUsage[account.id] = nil
                        accountUsageSampledAt[account.id] = nil
                        accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Session expired. Re-authenticate (↻) to fix.", bundle: L10n.bundle))
                    case .storeUnavailable:
                        // Nothing was spent and nothing is lost; this heals by
                        // itself on a later cycle. Keep the stale sample.
                        accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Could not save the refreshed sign-in; will retry automatically.", bundle: L10n.bundle))
                    }
                }
            } catch {
                log.error("[fetchUsage] Failed to get usage for \(account.email): \(error.localizedDescription)")
                accountUsage[account.id] = nil
                accountUsageSampledAt[account.id] = nil
                accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Could not fetch usage: \(error.localizedDescription)", bundle: L10n.bundle))
            }
        }
    }

    // MARK: - Diagnostics

    /// Message for the case where the CLI *is* authenticated but reports no
    /// account, because a credential source outranking the stored claude.ai login
    /// is in play. Without this the user only saw "Not logged in" / "Login did not
    /// complete" and re-authorized in a loop that could never help (issue #18).
    private func shadowedIdentityMessage(_ status: AuthStatus) -> String {
        let method = status.shadowingAuthMethod ?? "unknown"
        return String(localized: "Claude CLI is authenticating via \(method) instead of a stored claude.ai login, so it reports no account. Unset ANTHROPIC_AUTH_TOKEN / CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_PROFILE and remove any apiKeyHelper, then try again.", bundle: L10n.bundle)
    }

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
