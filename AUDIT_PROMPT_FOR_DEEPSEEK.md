# Independent Code-Review Prompt v2 — paste into DeepSeek V4 Pro

You are doing a **second, independent, hostile code review** of a Swift macOS menu-bar app called CCSwitcher. The previous reviewer found 5 issues; the author claims to have fixed 3 (HIGH-1, HIGH-2, MED-3) and explicitly deferred 2 (LOW-4, LOW-5). I want a fresh, skeptical pass that ignores those findings as priors and rebuilds your own threat model. Pretend you have never seen this code. Be terse. Cite line numbers from the diff. Skip code-style nits. ≤ 600 words total.

## System under review

- **App**: `~/dev/CCSwitcher` — Swift 6, macOS 14+, single-target menu-bar app, non-sandboxed main bundle, sandboxed widget extension. Bundle id `com.longnguyen.ccswitcher`. No SPM deps.
- **Concurrency model**: `AppState` is `@MainActor`-bound `ObservableObject`. `ClaudeService` is `final class … Sendable` (singleton via `static let shared`). `KeychainService` likewise.
- **What it does**: Per-account, stores `(accessToken, refreshToken, scopes…)` JSON blob in its own keychain entry (`me.xueshi.ccswitcher.backups`, kept for backwards compat across the bundle-id rename). On account-switch, reads target's blob and writes it to the *system* keychain entry that the Claude Code CLI reads (`Claude Code-credentials`). Also writes `oauthAccount` metadata to `~/.claude.json`. Does **not** restart the `claude` process — preserves live CLI sessions.
- **Bug being fixed**: Tokens minted before Anthropic added new OAuth scopes (`user:sessions:claude_code`, `org:sessions:claude_code`, `user:developer`, `workspace:developer`) silently fail Claude Code's cloud features (`/ultraplan`, etc.). Refresh-token grants cannot upgrade scopes; only a fresh authorization-code flow (`claude auth login`) can. Empirical signature: `GET /v1/environment_providers` → `403 OAuth token does not meet scope requirement any_of(...)`.
- **Fix**: Pre-write probe of `/v1/environment_providers`. 200 → swap. 403-with-substring → halt and surface re-auth message. Anything else → fail open.

## The full patch (this is everything that changed in source code; entitlements + bundle-id config omitted as out of review scope)

```diff
diff --git a/CCSwitcher/AppState.swift b/CCSwitcher/AppState.swift
@@ -284,6 +284,13 @@ final class AppState: ObservableObject {
     func switchTo(_ account: Account) async {
+        // Reentrancy guard: a switch in progress (e.g. waiting on the cloud-scope probe,
+        // ~1.2s window) must not be racing a second click.
+        guard !isLoading else {
+            log.info("[switchTo] Skipping: a switch is already in progress")
+            return
+        }
         guard let currentActive = activeAccount, currentActive.id != account.id else {
             log.info("[switchTo] No switch needed (same account or no active account)")
             return
         }
         …
         isLoading = true            // ← existing behavior; flips back to false at end
         do {
             try await claudeService.switchAccount(from: currentActive, to: account)
             …
         } catch {
             errorMessage = error.localizedDescription
             isLoading = false
         }

diff --git a/CCSwitcher/Services/ClaudeService.swift b/CCSwitcher/Services/ClaudeService.swift
@@ -176,6 +176,69 @@ final class ClaudeService: Sendable {
+    enum ScopeProbeResult: Sendable {
+        case ok
+        case staleScope
+        case transientError
+    }
+
+    func probeCloudScopes(accessToken: String) async throws -> ScopeProbeResult {
+        guard let url = URL(string: "https://api.anthropic.com/v1/environment_providers") else {
+            return .transientError
+        }
+        var request = URLRequest(url: url)
+        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
+        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
+        request.timeoutInterval = 8
+
+        do {
+            let (data, response) = try await URLSession.shared.data(for: request)
+            guard let http = response as? HTTPURLResponse else {
+                log.warning("[probeCloudScopes] non-HTTP response, treating as transient")
+                return .transientError
+            }
+            switch http.statusCode {
+            case 200:
+                log.info("[probeCloudScopes] HTTP 200 — cloud scopes present")
+                return .ok
+            case 403:
+                let body = String(data: data, encoding: .utf8) ?? ""
+                if body.contains("OAuth token does not meet scope requirement") {
+                    log.warning("[probeCloudScopes] HTTP 403 stale-scope — token needs re-auth")
+                    return .staleScope
+                }
+                log.warning("[probeCloudScopes] HTTP 403 (non-scope match) — body: \(body.prefix(200))")
+                return .transientError
+            default:
+                log.warning("[probeCloudScopes] HTTP \(http.statusCode) — transient")
+                return .transientError
+            }
+        } catch is CancellationError {
+            throw CancellationError()
+        } catch {
+            log.warning("[probeCloudScopes] error: \(error.localizedDescription) — transient")
+            return .transientError
+        }
+    }
+
@@ -207,6 +270,30 @@ final class ClaudeService: Sendable {
     func switchAccount(from currentAccount: Account, to targetAccount: Account) async throws {
         …
         // Step 1: backup current
         // Step 2: read target backup
         let targetEmail = (targetBackup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
         log.info("[switchAccount] Step 2: Target backup found (email=\(targetEmail))")
+        // Step 2.5 NEW
+        if let probeAccessToken = ClaudeService.extractAccessToken(from: targetBackup.token) {
+            switch try await probeCloudScopes(accessToken: probeAccessToken) {
+            case .ok: log.info("[switchAccount] Step 2.5: cloud scopes OK")
+            case .staleScope:
+                throw ClaudeServiceError.staleScope(email: targetAccount.email)
+            case .transientError:
+                log.warning("[switchAccount] Step 2.5: probe inconclusive — proceeding (fail-open)")
+            }
+        } else {
+            log.warning("[switchAccount] Step 2.5: could not extract accessToken from backup, skipping probe")
+        }
         // Step 3: write keychain + ~/.claude.json
         // Step 4: verify via `claude auth status`
     }

@@ enum ClaudeServiceError {
+    case staleScope(email: String)
@@ description {
+    case .staleScope(let email):
+        return "\(email)'s saved token is too old for cloud features (e.g. /ultraplan). Click \"Re-authenticate\" on this account to fix."
```

## Key surrounding context (not changed but relevant to interaction bugs)

```swift
// AppState.swift — pre-existing, runs every 5min auto-refresh
func refresh() async {
    guard !isLoggingIn else { return }
    isLoading = true       // ← shared flag with switchTo — can collide?
    errorMessage = nil
    claudeAvailable = await claudeService.isClaudeAvailable()
    if claudeAvailable {
        do { let status = try await claudeService.getAuthStatus(); … }
        catch { errorMessage = error.localizedDescription }
    }
    diagnoseTokenHealth()
    await fetchAllAccountUsage()        // ← multiple HTTPS calls, ~5s
    …
    isLoading = false
}
func startAutoRefresh(interval: TimeInterval = 300) { … fires refresh() every 5min … }
```

## Empirical evidence (4 live HTTP calls + 1 production failure log) underpinning detection logic

| Token state | HTTP | Body signal | Decision |
|---|---|---|---|
| Modern-scope (fresh `claude auth login`) | 200 | `{"environments":[…]}` | `.ok` → swap |
| Stale-scope | 403 | `OAuth token does not meet scope requirement any_of(user:sessions:claude_code,…)` | `.staleScope` → halt |
| Garbage Bearer | 401 | `authentication_error … x-organization-uuid header is required` | `.transientError` → swap (fail-open) |
| No auth header | 401 | `No valid authentication credentials provided` | `.transientError` → swap |

## What I want you to do

Pretend the v1.5 patch and the v1.5.1 follow-ups are both new to you. Find:

1. **Interaction bugs.** `refresh()` (auto-fires every 5 min) and `switchTo()` both set `isLoading = true`. Can `refresh()` running cause a user's account-switch click to silently no-op? If so — what's the worst-case symptom? Is the fix (use a separate flag, or make `switchTo` queue) better than the current `guard !isLoading`?
2. **Cancellation propagation.** The probe now `throws CancellationError`. Trace the call chain: `switchTo` → `switchAccount` → `probeCloudScopes`. If the parent `Task` is cancelled mid-probe, what does `AppState.switchTo`'s catch see? Does `error.localizedDescription` produce something a non-technical user can act on, or does it leak "The operation was cancelled" / Swift internals?
3. **The fail-open philosophy.** `transientError` proceeds with the swap. Step 4 (`claude auth status` verify) still runs after. Construct a real scenario where (a) probe returns `.transientError`, (b) Step 3 writes a garbage token, (c) Step 4's verify also fails, leaving the live keychain corrupted. Is the rollback story OK? (It currently *throws* on Step 4 failure but doesn't restore the previous account's token.)
4. **Async-throwing function safety.** `probeCloudScopes` returns `.transientError` for "URL malformed" (the `guard let url = URL(...)` early-return) but `throws` for cancellation. Is mixing return-and-throw on different failure modes confusing? Should it be all-throws or all-return?
5. **Substring match risk re-evaluated.** The fix added a log line on 403-non-match. But the user has to *check* logs. If Anthropic changes the substring tomorrow, every user silently corrupts their keychain until someone reads logs. Is "log on miss" sufficient, or should it be more conservative (e.g., treat *any* 403 as `.staleScope`)?
6. **Concurrency on `Sendable` singleton.** `ClaudeService.shared` is a `Sendable` `final class` with no internal locking. Multiple `Task`s can call `switchAccount` simultaneously (modulo AppState's reentrancy guard which is per-instance, not global). Are there shared mutable resources inside `ClaudeService` (the `Process` invocations, the `URLSession.shared`) that need protection? Does `URLSession.shared.data(for:)` block any keychain operation?
7. **Error-message UX.** `staleScope(email:)` uses an English literal that's not localized via `L10n.bundle` like other strings. Will it appear correctly in non-English locales? Will it actually surface in the menu bar (trace through `errorMessage = error.localizedDescription` → `MainMenuView`)?
8. **Hidden `MainActor` violation.** `ClaudeService.probeCloudScopes` is called from inside `switchAccount` which is called from `AppState.switchTo` (`@MainActor`). The HTTPS call hops off MainActor. When it resumes, does the throw-back to `switchTo`'s catch happen on MainActor? Any chance of UI updates from a non-main thread?
9. **Token leakage via logged URL or beta header.** Do the existing log lines anywhere in the patch include the access token, refresh token, or any token fragment? (Verify line by line.)
10. **Original 10 questions (deep-cut).** Review your priors; is there one you flagged before that the v1.5.1 fixes did NOT actually address despite the author's claim?

## Output format

- **Verdict**: ship / fix-then-ship / don't-ship
- **Findings** (numbered): file:line, severity (HIGH/MED/LOW), failure scenario in 1-2 sentences, minimal fix
- **Confirmed-fixed** list: which prior-review items the v1.5.1 patches genuinely address
- **What you'd test before shipping** (top 3, no more)

Skip generic advice ("add tests", "consider…"). Skip style nits. Cite line numbers from the diff above. ≤ 600 words.
