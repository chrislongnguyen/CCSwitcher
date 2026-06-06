---
name: plan-single-source-token
description: Eradicate the stale-token bug class — keychain as single source of truth, no active-account refresh, write-guarded switch rollback
status: draft
date: 2026-06-06
design_authority: ARCHITECTURE.md (token lifecycle) + 2026-06-06 live root-cause session
branch: fix/single-source-token
classification: INTERNAL
---

# PLAN — CCSWITCHER TOKEN LIFECYCLE: ERADICATE STALE-TOKEN CLASS

## GOAL

CC sessions NEVER get logged out by CCSwitcher; the "re-authenticate" badge clears and stays cleared; the stale-token bug class is structurally impossible (no second copy of the live token exists to go stale).

## ROOT CAUSE (verified 2026-06-06, log + source)

```
ROOT: ~/.ccswitcher/live-token.txt (file mirror)
      readClaudeToken() returns this FILE first; CLI writes ONLY the real keychain
      → mirror stale after every CLI /login AND every ~8h CLI self-refresh
         │                       │                        │
         ▼                       ▼                        ▼
   Backups never seeded    Self-heal compared       Failed-switch rollback wrote
   → proactiveRefresh      stale-vs-stale →         STALE backup over FRESH
   flogs dead tokens       silently no-oped         keychain → CC 401 logout
                                                    (log 12:02:56 writeClaudeToken=true)
```

Secondary hazard: app proactively refresh-grants the ACTIVE account's token, racing the
CC CLI — refresh tokens are single-use, dual rotation logs one writer out.

## LOCKED DESIGN DECISIONS (PM, 2026-06-06)

| # | DECISION | INVARIANT |
|---|---|---|
| **D1** | Kill the file mirror | Keychain = ONLY source of live-token truth. No code path reads/writes `~/.ccswitcher/live-token.txt` |
| **D2** | App never refreshes ACTIVE account | One writer per token: CC CLI owns active; app owns INACTIVE backups only |
| **D3** | Write-guard + verify on switch | Rollback fires ONLY if keychain was actually written; post-write identity verify before success |

## TASK TABLE

| ID | TYPE | ACTION | DEPS | VERIFY |
|---|---|---|---|---|
| **T1** | Machine | SPEC: surgical update of ARCHITECTURE.md §Token Lifecycle ONLY — D1/D2/D3 normative; mirror + active-refresh + "no-op rollback" claims marked SUPERSEDED with evidence; spike results/constants/Option B untouched | — | `rg -c "live-token.txt" ARCHITECTURE.md` → only superseded-design note |
| **T2** | Machine | KeychainService: `readClaudeToken()` keychain-only; delete `readTokenFromFile`/`saveTokenToFile`/`refreshTokenFile`/`liveTokenPath`; `writeClaudeToken` keychain-only; startup one-time delete of live-token.txt | T1 | `rg -c "liveTokenPath" CCSwitcher/` = 0; build OK |
| **T3** | Machine | AppState.updateActiveAccount: drop `refreshTokenFile()` band-aid (self-heal block stays) | T2 | `rg -c "refreshTokenFile" CCSwitcher/` = 0 |
| **T4** | Machine | refreshExpiringTokens + refreshAndRetryUsage: NEVER refresh-grant the active account (re-read keychain instead; CC CLI keeps it alive); inactive backups still refreshed | T2 | guard visible in source; log `skipping active` |
| **T5** | Machine | switchAccount/switchTo: `didWriteKeychain` flag; rollback no-ops when false; post-Step-3 identity verify | T2 | simulated dead-target switch leaves keychain byte-identical |
| **T6** | Machine | Quit app → `./scripts/build.sh release install` | T2-T5 | signature check passes; new log markers in binary |
| **T7** | **HUMAN** | `/login` once in CC (current keychain token is the stale one rollback wrote) | T6 | `claude auth status` loggedIn=true |
| **T8** | Machine | RUNTIME GATE: launch app, 2 cycles, assert in log: (a) self-heal capture fired for product@ (b) ZERO invalid_grant for product@ (c) `claude auth status` still loggedIn=true (d) switch to dead long@ fails WITHOUT keychain write | T7 | all 4 greps pass; any failure = STOP |
| **T9** | **HUMAN** | In-app re-auth long@ (token unrecoverable — keychain held one slot) | T8 | log `[capture] Save result: true` for long@ |
| **T10** | Machine | Re-run gate both accounts + real switch round-trip product@↔long@↔product@ with CC session surviving | T9 | round-trip clean; loggedIn=true after |
| **T11** | **HUMAN-gated** | Commit via /git-save after PM ratifies T10 evidence | T10 | — |

## CRITICAL PATH

`T1 → T2 → T5 → T6 → T7(human) → T8 → T9(human) → T10 → T11`
**BOTTLENECK: T2** — every code task depends on keychain-only read. T3/T4/T5 serial after it (single writer, same files).

## HARD CONSTRAINTS

- **No "works" claim before T8/T10 gates pass — log evidence or nothing.**
- Single writer: all code tasks inline, serial. No parallel agents on these files.
- App stays quit except during T8/T10 gates.
- long@'s token is dead regardless of plan — T9 unavoidable (Anthropic-side rotation).

## OUT-OF-SCOPE (deferred, named)

- Remove redundant `claude auth status` call from refresh hot path (popup cosmetics) — post-T10, separate change.
- Option B (delegate refresh to CLI) — revisit trigger unchanged in ARCHITECTURE.md.
