# Owned uninstall worker — 8 September 2026

InstallQueue now accepts a reviewed uninstall authorization and executes durable Remove files →
Remove bottle → Commit checkpoints. It uses the installed ownership token and exact recorded paths,
requires stopped game/wrapper processes, and verifies both locations are absent before clearing
installation state. Removal and retry do not need a store connection. Pausing/cancelling a confirmed
removal cannot expose a partially removed installation as playable; failures offer retry and shutdown
leaves a resumable queue checkpoint.

OwnedDirectoryRemoval publishes and fsyncs an external device/inode ownership receipt before any
recursive deletion. This survives loss of internal owner/config files during a partial deletion.
A retry rejects symlinks, another owner and replacement directories. Game files use this receipt;
CrossOver bottle removal still calls `cxbottle --delete --force`, with scoped cleanup if an interrupted
command already removed the configuration. Receipts are removed only after verified deletion.

Runtime checks reject live or omitted game/wrapper identities and known unreadable PIDs; a reused
PID with a different birth identity is not confused with the previous game. Ready/save access and
recreation remain blocked while a bottle removal receipt exists.

Validation:

- Added worker tests for removal/reinstall, failed bottle removal followed by restart/retry without
  a store, active-writer rejection before files change, and shutdown/restart during removal.
- Added concrete removal tests for partial deletion with missing internal markers, wrong ownership,
  replacement directories, symlinks and interrupted CrossOver deletion with missing configuration.
- Full `./scripts/test.sh`: 177 package XCTest tests (4 skips), 5 Swift Testing tests and 61 app tests
  passed. `/tmp/bigscreen-uninstall-worker-all-tests.log`.
- Opt-in real CrossOver probe: all 7 GameBottleTests passed, including a uniquely owned disposable
  clone/startup/delete. `/tmp/bigscreen-uninstall-real-bottle-probe.log`. No user game was uninstalled.

The app confirmation/Downloads integration is the next commit. Live A Short Hike uninstall/reinstall
and Cloud restore acceptance remain, along with real drive-disconnection during removal. As with
the existing filesystem ownership boundary, external processes replacing ancestors concurrently
are outside the normal app-controlled operation; owned roots and receipts are rechecked at each stage.
