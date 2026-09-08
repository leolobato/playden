# Uninstall controls — 8 September 2026

Replaced the live placeholder with a controller/keyboard dialog showing the game-file size, runtime
and local saves removed, and library metadata/Steam Cloud saves kept. Cancel is initially focused.
Confirming stops this game's session if necessary and checks Cloud before queueing removal. A failed
or unsupported sync requires a separate Discard and uninstall choice; conflicts can open save review.
Active sync/local-recovery guards remain authoritative. Discard uses the displayed review, and any
change makes the player review again rather than silently refreshing destructive consent.

Back or clicking outside cancels preparation before a removal job is created. Closing the Cloud
panel by mouse now also follows its normal cancellation behavior. Sign-out/termination cancels and
joins uninstall preparation; a confirmed durable removal job remains owned by the queue.

Downloads shows removal stages, failures/retry and Uninstalled completion. It does not offer download
pause/cancellation controls for removal. Details offers View removal while the job is unfinished.
New installations cannot inherit the previous installation's green Cloud status. Filesystem absence
checks also reject unreadable paths rather than treating permission errors as proof of deletion.

Validation:

- Six app tests cover normal confirmation/Cloud check, separate discard, stale consent, cancellation,
  removal controls/status and resetting Cloud status across reinstall.
- Added a real filesystem permission-denial test for removal receipts.
- `./scripts/test.sh`: 178 package XCTest tests (4 skips), 5 Swift Testing tests and 67 app tests
  passed, no failures. `/tmp/bigscreen-uninstall-ui-verified-tests.log`.
- Captured confirm, unsynced and checking states at 1080p in `.build/uninstall-ui/`; unsynced at 4K
  in `.build/uninstall-ui-4k/`. Visually inspected confirmation and unsynced dialogs at both sizes:
  readable text, complete action labels, one focus ring and no clipping. These are preview fixtures.

Live A Short Hike removal/reinstall/Cloud restoration follows this checkpoint. Its current game
container and owned bottle were copied to private `.build/uninstall-live-validation/` first for test
recovery. That private test backup is not a user-facing save-retention feature.
