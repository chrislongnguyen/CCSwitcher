# CCSwitcher Architecture

> **AUTHORITATIVE SECTION — added 2026-06-06. Supersedes any conflicting detail below.**
> Sections after this one (Keychain Token Storage, `security` CLI usage, keychain-backup
> model) predate the 2026-05-14 file-primary migration and the 2026-06-06 refresh-lifecycle
> work. Where they conflict with this section, THIS section is current. Stale parts are
> retained for history, not as a description of current behavior.

---

## Token Lifecycle & Refresh (the load-bearing design)

### The defect this section closes

CCSwitcher switched accounts by **snapshotting** each account's OAuth token to a backup
store (`~/.ccswitcher/backups.json`) and **replaying** the snapshot on switch. This model
died ~once per day across ~10 rebuilds (Apr–Jun 2026). Root cause, proven by live spike
2026-06-06: **Anthropic OAuth refresh tokens ROTATE.** Each successful refresh grant
invalidates the previous refresh token server-side. The moment the live `claude` CLI
refreshes an account once, every stored snapshot of that account holds a dead refresh
token. The backup-and-replay model is therefore **structurally incompatible with token
rotation** — no rebuild of that model survives past one rotation window.

> Note: CC auto-update was never the killer. Tokens expire on their own 8-hour clock
> regardless of CLI version. Pinning the CC version (see global `cc-autoupdate-disabled`)
> does not change token lifecycle. Treating "survives CC update" and "survives token
> expiry" as the same problem is what masked this root cause for 10 builds.

### Spike results — 2026-06-06 (verbatim, falsifiable signals)

Probes run locally, read-only, redacted. Endpoint, client_id, request shape, rotation
behavior all confirmed against the LIVE Anthropic OAuth service.

| # | Hypothesis | Verdict | Absolute signal |
|---|---|---|---|
| H1 | endpoint `platform.claude.com/v1/oauth/token` + client_id + JSON shape correct | ✅ VALIDATED | server returned structured `invalid_grant`, NOT `invalid_client` → request fully processed |
| H2 | stored backup refresh tokens still alive | ✗ FALSIFIED | both accounts: `HTTP 400 invalid_grant: "Refresh token not found or invalid"` |
| H3 | refresh tokens rotate (snapshots rot) | ✅ VALIDATED | live token refresh returned `rotated=True` |
| H5 | keychain popup = `security` CLI lost the entry's ACL after a rewrite | ✅ then self-resolved | CLI read hung 3s (blocked) → after re-grant, exit=0 free |
| H6 | Cloudflare WAF block is User-Agent-based | ✅ VALIDATED | plain `urllib` UA → `HTTP 403 error code: 1010`; CLI UA → passes |
| —  | live keychain token refresh end-to-end | ✅ VALIDATED | `HTTP 200 rotated=True expires_in=28800` (8h) |

**Constants confirmed live:**
- `TOKEN_ENDPOINT = https://platform.claude.com/v1/oauth/token` (legacy alias `console.anthropic.com/v1/oauth/token` exists; not used)
- `CLIENT_ID = 9d1c250a-e61b-44d9-88ed-5944d1962f5e` (public PKCE client; no client_secret)
- Required headers to clear Cloudflare 1010: `User-Agent: claude-cli/<ver> (external, cli)`, `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`
- Request body: `{"grant_type":"refresh_token","refresh_token":"<rt>","client_id":"<CLIENT_ID>"}`
- Response: `{access_token, refresh_token (ROTATED — must persist), expires_in: 28800, token_type, scope}`

### Option A — Direct refresh (CHOSEN, this build)

CCSwitcher refreshes tokens itself via the OAuth endpoint above.

```
SWITCH(target):
  1. back up current account (token + oauthAccount)        [unchanged]
  2. read target backup                                    [unchanged]
  2.5 probe target accessToken (probeCloudScopes)          [unchanged]
        .ok        -> proceed to write
        .staleScope-> halt, re-auth (scope upgrade needs browser; unchanged)
        .expired   -> *** NEW: attempt refreshGrant(target.refreshToken) ***
                        success -> WRITE-BACK rotated creds to backup store
                                   (atomic; chmod 600) THEN proceed with fresh token
                        failure (invalid_grant) -> halt, re-auth (genuinely dead)
        .transient -> proceed fail-open                    [unchanged]
  3. write token + oauthAccount to keychain / ~/.claude.json [unchanged]
  4. verify identity                                        [unchanged]

PROACTIVE (in AppState.refresh() periodic loop, BEFORE getUsageLimits):
  ACTIVE account: NEVER refresh-grant (D2, below). The CC CLI owns the active
     token and refreshes it on its own clock; the app re-READS the keychain
     and re-snapshots to backup when it differs (Seeding invariant, below).
  for each INACTIVE account whose token expiresAt < now + SKEW (e.g. 10 min):
     refreshGrant(refreshToken) -> WRITE-BACK to backup store
  This keeps inactive backups alive so a switch rarely hits the .expired path.

REACTIVE (getUsageLimits .expired / HTTP 401):
  ACTIVE account: re-read the keychain (the CLI may have already rotated it)
     and retry ONCE with the re-read token. NEVER refresh-grant (D2).
  INACTIVE account: refreshGrant(backup.refreshToken) -> WRITE-BACK -> retry ONCE.
```

> **SUPERSEDED 2026-06-06 (same-day, post-incident):** the original PROACTIVE/REACTIVE
> design had the app refresh-granting the ACTIVE account's token too. That is a
> dual-writer race: refresh tokens are single-use, the CC CLI also rotates the active
> token, and whichever writer refreshes second gets `invalid_grant` — observed live as
> CC-session logouts. Replaced by invariant D2.

**Normative invariants (locked 2026-06-06 after live root-cause; see PLAN-20260606-single-source-token.md):**

| # | INVARIANT |
|---|---|
| **D1** | **Single source of truth:** the macOS keychain entry is the ONLY copy of the live token. No file mirror. No code path may read or write `~/.ccswitcher/live-token.txt`; startup deletes it if present. All reads go through the app's native, stably-signed Security-framework read (popup-free; the historical popups came from the spawned CLI subprocess via `/usr/bin/security`, not native reads). |
| **D2** | **One writer per token:** the CC CLI owns the ACTIVE account's token lifecycle (login + rotation). The app refresh-grants ONLY INACTIVE accounts' backup tokens. The app's only writes to the live keychain are the switch path (Step 3) and in-app re-auth. |
| **D3** | **Write-guarded rollback:** a failed switch may restore the live keychain ONLY if the switch actually wrote it (Step 3 executed). Failures thrown before Step 3 (staleScope / expired / noToken) MUST NOT touch the keychain. After any keychain write, identity is verified before success is reported. |

> **SUPERSEDED 2026-06-06 — the file mirror (`~/.ccswitcher/live-token.txt`):** existed
> as popup insurance; `readClaudeToken()` preferred it over the keychain. The CLI writes
> only the keychain (`/login` AND its ~8h self-refresh), so the mirror was stale almost
> always. Every load-bearing read trusted it. Three observed failures from this one root:
> (1) backups never re-seeded → proactive refresh flogged dead tokens forever;
> (2) the seeding self-heal compared stale-mirror vs stale-backup → silent no-op;
> (3) `rollbackKeychain` after a failed switch wrote a stale backup OVER a fresh
> CLI login (log 2026-06-06 12:02:56) → repeated CC-session logouts. Its rollback
> comment claimed "no-op write of identical data" — false whenever the mirror was stale.
> Killed by D1.

**The non-negotiable invariant (the bug that kills every naive build):**
`refresh_token` is **single-use**. On every `HTTP 200`, the response's NEW `refresh_token`
MUST be written back to the backup store (and, for the active account, the keychain)
atomically, BEFORE the old one is discarded. A refresh that succeeds but fails to persist
the rotated token has *consumed and lost* the only valid credential → next refresh fails.
Write-back failure must roll back / re-fetch, never silently drop.

**Known dependencies (NOT deterministic / NOT "never fails"):** client_id validity,
endpoint stability, Cloudflare accepting the CLI UA (already tightening — 1010 is the
warning shot), and the refresh grant remaining open to public clients (no attestation).
All are undocumented, Anthropic-controlled surfaces that can change with zero notice.
Option A converts "fails every day on a fixed clock" → "fails only if Anthropic changes
OAuth internals." That is robust, not invulnerable.

**Seeding:** the two currently-stored accounts hold dead refresh tokens (H2). Each needs
ONE manual re-auth to seed a fresh token; proactive refresh keeps them alive thereafter.

**Seeding mechanism (the gap that survived the first build — closed 2026-06-06):**
"Re-auth seeds the backup store" was originally asserted without specifying HOW. There
are exactly two re-auth paths, and only one of them seeded:

| RE-AUTH PATH | WRITES LIVE KEYCHAIN | SEEDS BACKUP STORE |
|---|---|---|
| **In-app reauth flow** | ✅ (via CLI it spawns) | ✅ `captureCurrentCredentials` is called explicitly |
| **External CLI `/login`** | ✅ | ❌ nothing tells the app to re-snapshot (pre-fix) |

Observed live 2026-06-06: both accounts re-authed via CLI → live keychain fresh
(`getAuthStatus loggedIn=true`) while both backups still returned `invalid_grant` on
every proactive cycle. The refresh engine was correct; its input was never re-seeded.

**Seeding invariant (normative):** whenever the live keychain token for the ACTIVE
account differs from that account's backup-store snapshot, the app MUST re-capture
(live → backup) on the next refresh cycle. Implemented in
`AppState.updateActiveAccount` (self-heal block). Under D1 the comparison reads the
keychain directly — there is no mirror to go stale. This makes the active account's
seeding path-independent: CLI `/login`, in-app reauth, or any future path all converge.
LIMIT: this heals the ACTIVE account only — the keychain holds one token at a time, so
an INACTIVE account re-authed externally is overwritten by the next login and can only
be seeded via the in-app reauth flow (which captures immediately, while it is active).

### Option B — Delegate to `claude auth status` (DEFERRED — future fallback)

Upstream `XueshiQiao/CCSwitcher` deliberately refuses direct POST. Instead: on `401`,
spawn `claude auth status` as a background subprocess; the official CLI performs the
refresh using its own (possibly attested) client; CCSwitcher re-reads the keychain after.

| | Option A (chosen) | Option B (deferred) |
|---|---|---|
| Speed | fast, in-process | slower (subprocess spawn) |
| Durability vs Anthropic OAuth changes | breaks if attestation/client_id/endpoint changes | survives — rides the official client |
| Complexity | refresh + write-back + rotation handling | subprocess orchestration + keychain re-read |

**Revisit trigger:** if Option A starts returning `403 1010` (TLS/JA3 attestation) or
`invalid_client` on a known-good token, switch the refresh strategy to Option B. The
switch flow (steps 1–4) is unchanged; only the `.expired` recovery action swaps from
`refreshGrant()` to `triggerCliRefresh()`. Architect the refresh call behind a small
`TokenRefresher` protocol so A↔B is a one-implementation swap, not a rewrite.

### Features that MUST NOT regress (verified working pre-build 2026-06-06)

- **Usage** (`getUsageLimits` → `api.anthropic.com/api/oauth/usage`) — renders session/weekly %. NB: the "API Rate Limited" / failed-usage state observed 2026-06-06 is downstream of the **stale token** (the app holds no fresh token), NOT a real upstream rate limit. Once the active token is refreshed and live, usage resolves. This is part of the same root cause — a symptom of the dead-token model, not a separate feature bug.
- **Costs** (`SessionParseCache` + `CostParser`) — today / 7d / 30d / daily history.
- **Activity** (`StatsParser`) — turns / active time / lines / per-model token split.
- **JSONL parse cache** (`SessionParseCache`, commit `d7aaf8f`) — mtime-keyed; fixed the 100% idle-CPU bug. Refresh work must not bypass or thrash this cache.

---

## Keychain Token Storage

CCSwitcher manages two sets of keychain entries:

```
macOS Keychain
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│  ┌─ Claude CLI owns this entry ─────────────────────────┐   │
│  │  Service:  "Claude Code-credentials"                  │   │
│  │  Account:  "<OS username>"  (e.g. "joey")             │   │
│  │  Password: <Active OAuth Token JSON>                  │   │
│  │                                                       │   │
│  │  Claude CLI reads/writes this to authenticate.        │   │
│  │  CCSwitcher accesses it via `security` CLI tool       │   │
│  │  (NOT Security framework) to avoid repeated password  │   │
│  │  prompts. User clicks "Always Allow" once.            │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─ CCSwitcher owns these entries ──────────────────────┐   │
│  │  Service:  "com.ccswitcher.tokens"                    │   │
│  │  Account:  "<Account-A UUID>"                         │   │
│  │  Password: <Account A's backed-up OAuth Token JSON>   │   │
│  │                                                       │   │
│  │  Service:  "com.ccswitcher.tokens"                    │   │
│  │  Account:  "<Account-B UUID>"                         │   │
│  │  Password: <Account B's backed-up OAuth Token JSON>   │   │
│  │                                                       │   │
│  │  Also accessed via `security` CLI — during dev builds │   │
│  │  code signature changes each time, so the Security    │   │
│  │  framework would prompt repeatedly.                   │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Token JSON Format

The token stored in keychain is a single JSON object (captured from real keychain entry):

```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-************************************************************-hZQ2uQAA",
    "refreshToken": "sk-ant-ort01-************************************************************-MO7X_wAA",
    "expiresAt": 1774128766541,
    "scopes": [
      "user:file_upload",
      "user:inference",
      "user:mcp_servers",
      "user:profile",
      "user:sessions:claude_code"
    ],
    "subscriptionType": "pro",
    "rateLimitTier": "default_claude_ai"
  }
}
```

**Key observations:**
- `accessToken` prefix: `sk-ant-oat01-` (OAuth Access Token)
- `refreshToken` prefix: `sk-ant-ort01-` (OAuth Refresh Token)
- `expiresAt` is a Unix timestamp in **milliseconds** (not seconds)
- `scopes` is an **array of strings** (not a single string)
- The token JSON does **NOT** contain email or account identity — the only way to determine which account a token belongs to is by calling `claude auth status` while that token is active
- This lack of embedded identity is why CCSwitcher must verify CLI state before backing up tokens (see "Token Corruption Prevention" below)

### Token Corruption Prevention

A critical invariant: each account's backup token must belong to that account.
Since the token JSON contains no email/identity, CCSwitcher cannot verify ownership
from the token alone. To prevent saving the wrong token under the wrong account:

1. **Before backup**: always call `claude auth status` and verify the email matches
   the account we're about to back up for
2. **After switch**: verify `claude auth status` returns the target account's email,
   not just `loggedIn: true`
3. **Passive diagnostics**: on every refresh, extract token fingerprints (last 8 chars
   of accessToken) for all backups and the live token, and log warnings if:
   - Two different accounts share the same fingerprint (duplicate/corrupted backup)
   - The live token doesn't match the active account's backup (state desync)

---

## `claude auth login` — OAuth Flow

When `claude auth login` runs, it performs a standard **OAuth 2.0 Authorization Code + PKCE** flow:

```
Claude CLI                    Browser                   claude.ai Server
    │                            │                            │
    │  1. Start local HTTP       │                            │
    │     server (random port)   │                            │
    │                            │                            │
    │  2. Build OAuth URL:       │                            │
    │     https://claude.ai/oauth/authorize                   │
    │     ?redirect_uri=http://localhost:<port>/oauth/callback │
    │     &code_challenge=<PKCE SHA256>                       │
    │     &code_challenge_method=S256                         │
    │                            │                            │
    │  3. open(URL) ────────────►│                            │
    │     (system default browser)│                           │
    │                            │  4. User logs in           │
    │                            ├───────────────────────────►│
    │                            │                            │
    │                            │  5. Server returns          │
    │                            │     auth code via redirect  │
    │                            │◄───────────────────────────┤
    │                            │                            │
    │  6. Browser redirects to:  │                            │
    │     localhost:<port>/      │                            │
    │     oauth/callback?code=xx │                            │
    │◄───────────────────────────┤                            │
    │                            │                            │
    │  7. Exchange code + PKCE   │                            │
    │     verifier for tokens    │                            │
    │────────────────────────────────────────────────────────►│
    │◄────────────────────────────────────────────────────────┤
    │     {accessToken, refreshToken, expiresAt, ...}         │
    │                            │                            │
    │  8. Store in macOS Keychain│                            │
    │     service: "Claude Code-credentials"                  │
    │     account: "<OS username>"                            │
    │     password: JSON with OAuth tokens                    │
    │                            │                            │
    │  9. Close local server     │                            │
    │     Exit process (code 0)  │                            │
```

**Key points:**
- The CLI starts a **local HTTP server on a random port** as the OAuth redirect target
- Uses **PKCE** (Proof Key for Code Exchange) to prevent authorization code interception
- The process **blocks until the browser callback arrives** — `Process.waitUntilExit()` waits for login completion
- Token is written to Keychain **before** the process exits, so reading it immediately after is safe
- The login **always replaces** the current Claude Code session — this is Claude CLI's own behavior

---

## Account Switching (A → B) — Complete Token Flow

**Precondition:** App has Account-A (active) and Account-B. User clicks "Switch" on B.

Token notation: `T-A` = Account A's OAuth token, `T-B` = Account B's OAuth token.
Fingerprint notation: `fp(T-X)` = last 8 chars of accessToken in T-X.

```
                                    ┌─ Keychain State ─────────────────────────┐
                                    │ LIVE: "Claude Code-credentials" = T-A    │
                                    │ Backup UUID-A: T-A                       │
                                    │ Backup UUID-B: T-B                       │
                                    └──────────────────────────────────────────┘

Step 0: PRE-CHECK — read backup fingerprints (keychain only, no CLI call)

    Read Backup UUID-A → fp(T-A)
    Read Backup UUID-B → fp(T-B)

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if fp(T-A) == fp(T-B):                                                 │
    │   → ABORT: "Both accounts have the same token."                        │
    │   → Show error: "Use re-authenticate (↻) to fix."                     │
    │   → This catches the corruption bug BEFORE doing any damage.           │
    │   → return early, no keychain writes                                   │
    │                                                                         │
    │ if fp(T-A) != fp(T-B):                                                 │
    │   → OK, proceed to step 1                                              │
    └─────────────────────────────────────────────────────────────────────────┘

Step 1: VERIFY CLI state, then conditionally back up source token

    Run `claude auth status` → returns { email: "?" }

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if email == A.email:                                                    │
    │   → CLI is on Account A (expected). Safe to backup.                    │
    │   → Read LIVE token (T-A) → Write to Backup UUID-A                     │
    │                                                                         │
    │   Keychain after:                                                       │
    │     LIVE = T-A, Backup UUID-A = T-A (refreshed), Backup UUID-B = T-B  │
    │                                                                         │
    │ if email != A.email:                                                    │
    │   → CLI is NOT on Account A (state desync).                            │
    │   → SKIP backup. The LIVE token belongs to someone else.               │
    │   → Writing it to Backup UUID-A would corrupt A's backup.              │
    │                                                                         │
    │   Keychain after: unchanged                                             │
    └─────────────────────────────────────────────────────────────────────────┘

Step 2: Read target backup

    Read Backup UUID-B → T-B
    (if missing → throw error, cannot switch)

Step 3: OVERWRITE the LIVE slot with target token

    Delete LIVE entry, then Write T-B → LIVE

    ┌─ Keychain State ─────────────────────────────────────────────────┐
    │ LIVE: "Claude Code-credentials" = T-B   ← CHANGED               │
    │ Backup UUID-A: T-A                                               │
    │ Backup UUID-B: T-B                                               │
    └──────────────────────────────────────────────────────────────────┘

    From this moment, any `claude` CLI call uses T-B (Account B's token).

Step 4: VERIFY the switch worked

    Run `claude auth status` → returns { authMethod, email?, loggedIn }

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if !loggedIn:                                                           │
    │   → Token invalid. throw switchVerificationFailed                      │
    │                                                                         │
    │ if email == B.email:                                                    │
    │   → SUCCESS. Claude CLI now operates as Account B.                     │
    │                                                                         │
    │ if email is present but != B.email:                                    │
    │   → Backup T-B was CORRUPTED (contained wrong account's token).        │
    │   → throw switchWrongAccount(expected: B, actual: email)               │
    │   → User sees: "Switch failed: expected B@... but got A@...            │
    │     Try removing and re-adding the account."                           │
    │                                                                         │
    │ if email is ABSENT (authMethod != "claude.ai"):                        │
    │   → Says NOTHING about our swap — see the note below.                  │
    │   → Fall back to a local check: LIVE keychain accessToken == T-B's,    │
    │     and ~/.claude.json identity == B.email.                            │
    │   → match    → SUCCESS, plus a warning naming the shadowing source.    │
    │   → mismatch → throw switchVerificationFailed                          │
    └─────────────────────────────────────────────────────────────────────────┘

    ⚠️  `claude auth status` only emits `email` / `orgId` / `orgName` /
        `subscriptionType` when `authMethod == "claude.ai"`, i.e. when the
        stored claude.ai login is the credential source the CLI actually
        resolves to. Any higher-precedence source shadows it and the whole
        identity block is omitted while `loggedIn` stays `true`:
        `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, an `apiKeyHelper`,
        an OAuth token file, an Anthropic profile in `~/.config/anthropic`,
        or a third-party provider (Bedrock/Vertex/…). Treating that absence
        as "wrong account" produced the bogus
        "Switch failed: expected <email> but got unknown" of issue #18, even
        though both halves of the swap had been written correctly.

Step 5: POST-SWITCH diagnostics

    Read LIVE → fp(LIVE)
    Compare fp(LIVE) == fp(T-B)?  (should match, log warning if not)

    Update app state: A.isActive=false, B.isActive=true, activeAccount=B
```

---

## Login New Account — Complete Token Flow

**Precondition:** App has Account-A (active). LIVE keychain = T-A.
User clicks "Login New Account" and logs in as B (or A again) in browser.

```
                                    ┌─ Keychain State ─────────────────────────┐
                                    │ LIVE: "Claude Code-credentials" = T-A    │
                                    │ Backup UUID-A: T-A                       │
                                    └──────────────────────────────────────────┘

Step 0: Record pre-login fingerprint (keychain read only)

    Read LIVE → T-A → fp_before = fp(T-A)

Step 1: VERIFY CLI, then conditionally back up current account

    Run `claude auth status` → returns { email: "?" }

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if email == A.email:                                                    │
    │   → CLI matches active account. Safe to backup.                        │
    │   → Read LIVE (T-A) → Write to Backup UUID-A                           │
    │   (This ensures A's backup has the freshest token before we replace it)│
    │                                                                         │
    │ if email != A.email:                                                    │
    │   → State desync. SKIP backup to avoid corruption.                     │
    │   → A's existing backup (from when it was first added) remains intact. │
    └─────────────────────────────────────────────────────────────────────────┘

Step 2: Run `claude auth login` (opens browser, blocks until complete)

    Claude CLI starts local HTTP server → opens browser → user logs in.

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ SCENARIO A: User logs in as DIFFERENT account (B)                      │
    │   → Claude CLI receives new OAuth tokens for B                         │
    │   → CLI writes T-B (new token) to LIVE keychain entry                  │
    │   → CLI process exits (code 0)                                         │
    │                                                                         │
    │   Keychain after:                                                       │
    │     LIVE = T-B  ← CHANGED by Claude CLI                                │
    │     Backup UUID-A = T-A  (preserved)                                   │
    │                                                                         │
    │ SCENARIO B: User logs in as SAME account (A again)                     │
    │   → Claude CLI receives new OAuth tokens for A                         │
    │   → CLI writes T-A' (new/refreshed token for A) to LIVE               │
    │   → CLI process exits (code 0)                                         │
    │                                                                         │
    │   Keychain after:                                                       │
    │     LIVE = T-A'  ← CHANGED (refreshed A token, different from old T-A)│
    │     Backup UUID-A = T-A  (old token, still valid until expiry)         │
    └─────────────────────────────────────────────────────────────────────────┘

Step 3: Read new token, compare fingerprint

    Read LIVE → new token → fp_after

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if fp_after != fp_before:                                               │
    │   → Token changed. This confirms a new login happened.                 │
    │   → Could be different account OR same account with refreshed token.   │
    │   → Log: "Token fingerprint CHANGED (xxxx → yyyy)"                     │
    │                                                                         │
    │ if fp_after == fp_before:                                               │
    │   → Token did NOT change. Possible causes:                             │
    │     - Login didn't actually complete (user closed browser)             │
    │     - User logged into same account AND server returned same token     │
    │   → Log WARNING (but continue — step 4 will determine via email)      │
    └─────────────────────────────────────────────────────────────────────────┘

Step 4: Get auth status to identify WHO is logged in

    Run `claude auth status` → returns { email: "X@...", loggedIn: true }

    (if !loggedIn → error "Login did not complete", return early)

Step 5: Duplicate check by email

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if email already exists in accounts[]:                                  │
    │   → User logged in as an account we already have.                      │
    │   → Read LIVE → Write to that account's backup UUID (refresh token)    │
    │   → Show: "Account already exists - token refreshed"                   │
    │   → return early (no new account created)                              │
    │                                                                         │
    │   Example: user has A, logs in as A again.                             │
    │   Result:                                                               │
    │     LIVE = T-A' (refreshed)                                            │
    │     Backup UUID-A = T-A' (updated)                                     │
    │     Account list unchanged. A stays active.                            │
    │                                                                         │
    │ if email is NEW (not in accounts[]):                                    │
    │   → This is a genuinely new account. Proceed to step 6.               │
    └─────────────────────────────────────────────────────────────────────────┘

Step 6: Create new account, capture its token

    Create Account-B model (email, org, subscription from status)
    Read LIVE (T-B) → Write to Backup UUID-B

    ┌─ Keychain State ─────────────────────────────────────────────────┐
    │ LIVE: "Claude Code-credentials" = T-B                            │
    │ Backup UUID-A: T-A  (Account A's original token, preserved)     │
    │ Backup UUID-B: T-B  (Account B's fresh token)                   │
    └──────────────────────────────────────────────────────────────────┘

Step 7: Update app state

    for all accounts: isActive = false
    Append Account-B to accounts[]
    activeAccount = Account-B
    Save to UserDefaults

    ┌─ Final State ────────────────────────────────────────────────────┐
    │ App: Account-A (inactive), Account-B (active)                    │
    │ Keychain LIVE = T-B (Account B)                                  │
    │ Keychain Backup UUID-A = T-A (Account A — ready for switch)     │
    │ Keychain Backup UUID-B = T-B (Account B)                        │
    │                                                                   │
    │ User can now click "Switch" on Account-A to go back.            │
    │ That will: write T-A → LIVE, verify email == A → done.          │
    └──────────────────────────────────────────────────────────────────┘
```

---

## Re-authenticate Account — Complete Token Flow

Used to fix a stale/corrupted backup token without removing the account.
The user must log in as the **same email** as the account being re-authenticated.

**Example:** Account-A's backup was corrupted (contains T-B instead of T-A).

```
                                    ┌─ Keychain State (CORRUPTED) ─────────────┐
                                    │ LIVE: "Claude Code-credentials" = T-B    │
                                    │ Backup UUID-A: T-B  ← WRONG! should be  │
                                    │                       T-A                │
                                    │ Backup UUID-B: T-B                       │
                                    └──────────────────────────────────────────┘

    User clicks ↻ on Account-A.

Step 1: Back up current active account (if different from target)

    Active account = B, target = A, so active != target.
    Run `claude auth status` → email == B.email?
      YES → Read LIVE (T-B) → Write to Backup UUID-B (refresh B's backup)

Step 2: Run `claude auth login` (opens browser)

    User must log in as A@... in the browser.
    CLI writes T-A' (fresh token for A) → LIVE

    ┌─ Keychain State ─────────────────────────────────────────────────┐
    │ LIVE = T-A'  ← CHANGED by CLI                                   │
    │ Backup UUID-A: T-B  (still corrupted, not yet fixed)            │
    │ Backup UUID-B: T-B  (correct)                                   │
    └──────────────────────────────────────────────────────────────────┘

Step 3: VERIFY email matches the target account

    Run `claude auth status` → returns { email: "?" }

    ┌─────────────────────────────────────────────────────────────────────────┐
    │ if email == A.email:                                                    │
    │   → Correct! User logged in as the right account. Proceed to step 4.  │
    │                                                                         │
    │ if email != A.email:                                                    │
    │   → User logged in as the wrong account.                               │
    │   → Show error: "Logged in as X, but expected A. Token not updated."   │
    │   → return early. Backup UUID-A NOT overwritten (still corrupted,      │
    │     but at least we didn't make it worse).                             │
    └─────────────────────────────────────────────────────────────────────────┘

Step 4: Capture fresh token for the target account

    Read LIVE (T-A') → Write to Backup UUID-A

    ┌─ Keychain State (FIXED) ─────────────────────────────────────────┐
    │ LIVE = T-A'  (Account A is now active in CLI)                    │
    │ Backup UUID-A: T-A'  ← FIXED! Now contains A's real token      │
    │ Backup UUID-B: T-B   (correct)                                  │
    └──────────────────────────────────────────────────────────────────┘

Step 5: Update app state

    Account-A becomes active (it's what CLI is using now).
    User can switch back to B whenever they want.
```

---

## Passive Token Health Check (runs every 30s refresh)

No CLI calls. Keychain reads only. Detects problems without triggering any login.

```
diagnoseTokenHealth()
 │
 ├── Read LIVE token from "Claude Code-credentials"
 │   → extract fp(LIVE) = last 8 chars of accessToken
 │
 ├── For each account in accounts[]:
 │   └── Read Backup from "com.ccswitcher.tokens/<UUID>"
 │       → extract fp(backup)
 │       → if missing: log WARNING "account has no stored token, switch will fail"
 │
 ├── CHECK 1: Duplicate fingerprints across different accounts
 │   │
 │   │  Example of CORRUPTION:
 │   │    Account A backup fp = "hZQ2uQAA"
 │   │    Account B backup fp = "hZQ2uQAA"  ← SAME!
 │   │
 │   └── log ERROR: "CORRUPTION DETECTED: accounts [A, B] share the
 │       same token fingerprint. Use re-authenticate (↻) to fix."
 │
 └── CHECK 2: LIVE token vs active account's backup
     │
     ├── fp(LIVE) == fp(active account backup)
     │   └── log INFO: "Live token matches active account backup — OK"
     │
     ├── fp(LIVE) == fp(OTHER account backup)
     │   └── log WARNING: "STATE DESYNC: live token matches [other]
     │       but active is [active]. CLI may have been switched externally."
     │
     └── fp(LIVE) matches NO backup
         └── log WARNING: "live token doesn't match any backup.
             Token may have been refreshed by Claude CLI."
```

---

## Why `security` CLI Instead of Security Framework?

| Concern | Security Framework | `security` CLI |
|---------|-------------------|----------------|
| Claude's keychain entry | Prompt every access (we don't own the ACL) | "Always Allow" persists |
| Our own keychain entries | Prompt on every Debug rebuild (code signature changes) | "Always Allow" persists |
| Production (signed) builds | Would work without prompts | Also works |
| Recommendation | Only for signed production builds | **Use for all builds** |

---

## Data Flow Overview

```
┌─────────────────────────────┐
│      ~/.claude/             │
│  ├── stats-cache.json ──────┼──► StatsParser ──► UsageSummary
│  └── sessions/*.json ───────┼──► StatsParser ──► [SessionInfo]
└─────────────────────────────┘

┌─────────────────────────────┐
│      Claude CLI             │
│  `claude auth status` ──────┼──► ClaudeService ──► AuthStatus
│  `claude auth login`  ──────┼──► ClaudeService (opens browser)
└─────────────────────────────┘

┌─────────────────────────────┐
│      macOS Keychain         │
│  Claude Code-credentials ───┼──► KeychainService (via `security` CLI)
│  com.ccswitcher.tokens/* ───┼──► KeychainService (via `security` CLI)
└─────────────────────────────┘

         All services feed into:
    ┌──────────────────────────┐
    │  AppState (@MainActor)   │
    │  ├── accounts            │
    │  ├── activeAccount       │
    │  ├── usageSummary        │
    │  └── recentActivity      │
    └──────────┬───────────────┘
               │ @EnvironmentObject
    ┌──────────▼───────────────┐
    │  SwiftUI Views           │
    │  ├── MainMenuView        │
    │  ├── UsageDashboardView  │
    │  ├── AccountSwitcherView │
    │  └── SettingsView        │
    └──────────────────────────┘
```

---

## SwiftUI Settings Window Workaround for LSUIElement

Because CCSwitcher is a pure menu bar application (`LSUIElement` = `true` in `Info.plist`), SwiftUI's native `Settings { ... }` scene and `SettingsLink` often fail to open or gain foreground focus. This happens because SwiftUI does not consider the application to have any active interactive scenes when only a `MenuBarExtra` is present.

To circumvent this macOS limitation, CCSwitcher uses the **Lifecycle Keepalive** pattern:

1. **Hidden Keepalive Window:** At startup, we declare a 1x1 pixel `WindowGroup("CCSwitcherKeepalive") { HiddenWindowView() }`.
2. **True Invisibility:** The `HiddenWindowView` intercepts its own NSWindow on appearance and sets it to be `[.borderless]`, `alphaValue = 0`, positioned far off-screen (`x: -5000, y: -5000`), and configured to ignore all mouse events.
3. **Triggering Settings:** `HiddenWindowView` listens for a custom `Notification.Name.ccswitcherOpenSettings` via Combine. When received, it invokes the native SwiftUI `@Environment(\.openSettings)` action.
4. **Invocation:** In `MainMenuView`, when the user clicks the Settings gear icon, we post this notification. The hidden window (which SwiftUI recognizes as a valid, active scene) catches it and smoothly opens the native Settings window with proper focus.

