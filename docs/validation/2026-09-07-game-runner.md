# Game runner checkpoint — 7 September 2026

`CrossOverRunner` implements the injected `GameRunner` protocol for owned bottle preparation,
literal launch arguments, process/window observation, termination and recovery. The app's Play
button is not wired to this service yet; session orchestration and presentation are the next step.

## Process evidence and implementation

The live Oniken probe showed that Wine game and service processes can share the same macOS
`proc_pidpath`, and game children can be reparented to PID 1. The inspector therefore reads the
current user's candidate Wine processes through libproc/KERN_PROCARGS2, retains only `WINEPREFIX`
from their environment, and matches the exact bottle path. It identifies Windows services from
their Windows system path and observes windows only for matching game processes. A process identity
contains PID plus kernel start seconds/microseconds; a PID alone is never used for recovery or signals.

The directly spawned launcher owns a process group and a bounded nonblocking output pipe. The
runner keeps observing if its wrapper exits while a game child is alive. Lingering Wine services
alone do not keep a finished session alive. A short empty transition permits launcher/child handoff;
there is no arbitrary timeout on a live game or a game still launching. Transient inspection failures
preserve the tracked run instead of treating it as exited.

Quit rechecks bottle ownership and the observed wineserver identity. Graceful close uses the scoped
Wine end-session/shutdown command. Force first stops the tracked launcher group, then issues the
bottle-scoped wineserver kill. The session service will own the ten-second escalation policy.
The force flag is explicit: Oniken's wrapper returned zero after a forced quit, so that status alone
would incorrectly label it clean.

`recover` accepts a saved runtime snapshot, revalidates ownership and process birth identities, and
reattaches to a still-live game. It refuses to adopt reused PIDs or a replacement wineserver. A
recovered non-child's exit status remains unknown. `PlaySessionRecord.runtime` is optional so old
session records remain decodable; saving/reconciling it in the app is still pending.

## Validation

- `./scripts/test.sh`: 65 package XCTest cases (3 optional probes skipped), 5 focus tests and
  40 app tests: **107 passed, 3 skipped**, no failures.
- Seven new runner tests cover wrapper-to-child lifetime, lingering services, inaccessible process
  inspection, reused server PIDs, early launch failure, one active game, literal arguments/path
  containment, kernel argument parsing without retaining unrelated environment data, real child
  exit status/redaction, and restart recovery without invented status.
- A temporary harness compiled the current Runner sources and used Oniken's verified ownership
  receipt. It called prepare/launch/observe, observed a real Oniken launcher window, requested graceful
  closure, waited ten seconds, and escalated only if still active. The recorded terminal event had
  `hadWindow=true`, `forced=true`, and wrapper exit code `143` after stopping the launcher group.
  The earlier probe returned `0` when wineserver was stopped first; both require the explicit force flag.
- The initial real window was captured and opened (`/tmp/bigscreen-oniken-first-window.png`). It is
  Oniken's Windows launcher, not evidence of player-controlled gameplay. Its launcher-to-game
  interaction and physical controller handoff remain unproven.

The native CLI interface was checked using the installed CrossOver 26.2 `cxstart --help` and its
wrapper source. No game binaries or CrossOver binaries are modified by this change.

## Open acceptance

The full PRD 06 journey is not complete: Play UI, launching screen, first-window foreground handoff,
background hold-Home routing, exit overlay, monotonic session checkpoints, startup reconciliation
before downloads, crash presentation and download pause/resume still need integration and testing.
The accepted implementation plan's rule that a short clean session remains clean also needs to be
applied consistently when classifying session outcomes; runtime duration alone is not crash evidence.
