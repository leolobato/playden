# Failure retry controls — 8 September 2026

Launch/crash notifications previously offered View logs and Dismiss only. They now also offer
Retry. The failed request captures its game identity, so browsing to another title cannot change
which game is retried. Failures before a new session is reserved also point View logs at the
requested game, rather than a previous session's game. Unrelated failures clear that context.

Session startup recovery and download-pause-policy failures carry distinct retry actions. Retrying
those operations does not launch the last-played game. Launch retries use SessionService's normal
checks and durable preparation receipts; successful prerequisite/source work is retained.
Existing active-session, busy and reset guards still apply.

The log viewer offers Retry for the latest failed install, repair or removal job and the latest
failed/crashed play session. Retry cancellation retains cancellation intent. A persisted failed
session can be retried after reopening the app or dismissing its notification. The action checks
the operation identity again before execution; an older log cannot retry a replacement job or
superseded session. Close remains the initial log action, with horizontal navigation to Retry
and Reveal in Finder when available; vertical/page input continues to scroll the log.

## Evidence

- Full package suite: 243 XCTest tests, 6 opt-in skips, plus 5 Swift Testing tests, no failures.
  Initial app suite: 115 tests passed. `/tmp/bigscreen-failure-retry-all-tests.log`.
- After adding persisted-log coverage and using Catalog's actual generated play-session log,
  all 116 app tests passed. `/tmp/bigscreen-failure-retry-final-app-tests.log`.
- Regressions cover a changed selected game, failure before session reservation, session-startup
  retry, blocked retry while another game runs/reset is active, reopening a persisted failed
  session, superseded session/job identity and cancellation intent.
- Signed build passed. `/tmp/bigscreen-failure-retry-build.log`.
- Actual native captures at 1080 and 4K with reduced motion show the focused Retry notification
  and log action: `.build/failure-retry-1080/` and `.build/failure-retry-4k/`.

## Separate current-build shortcut check

The earlier inconclusive global CGEvent test was repeated using System Events, the input path
already validated on 7 September. On the actual A Short Hike session
`ABD15C5C-F533-4507-A162-379BD0CF3032`, Shift–Home opened the exit panel at window level 27.
Return dismissed it; another Shift–Home reopened it; Quit stopped the owned game via its force
fallback and finalized the session. No new gameplay save was created by this menu-only check.
Evidence: `.build/shortcut-current-live/overlay.png` and before/after session records.

This resolves the synthetic-shortcut discrepancy; no shortcut code change was required. The
game activation warning remained visible during that check; the subsequent
[observed focus handoff fix](2026-09-08-game-focus-handoff.md) verified automatic activation,
Return, and keyboard input with no stale warning. Physical
DS4/TV hold-Home and gameplay input leakage are not established by this keyboard check.
