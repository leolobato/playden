# Setup and runtime validation — 2026-09-07

Environment: Apple Silicon Mac17,9, macOS 26.6.2, Xcode 26.3 / Swift 6, CrossOver 26.2.
This extends the foundation and account evidence; it is not a gameplay acceptance result.

## Services and automated checks

The Runner module's finite-command executor passes arguments directly to `posix_spawn`, captures
at most 256 KiB of output, starts a separate process group, and resets inherited signal masks.
Timeout/cancel sends TERM to the group, then KILL after two seconds if necessary. Tests exercise
literal arguments, output flooding, a group that ignores TERM, cancellation and a missing tool.
The executor is for setup commands; a game's process/window lifetime still needs its own supervisor.

`CrossOverRuntime` creates the pinned `gn-template-1` Windows 10 64-bit template with MSync and
D3DMetal settings. A durable reservation, unique description in CrossOver's configuration and an
ownership marker identify the app's folder. Existing unowned bottles and replaced/symlinked folders
are rejected. Ready state requires configuration validation and a successful Windows startup
command. Failed stages are retained with redacted output and can be retried without recreating an
already owned template. The implementation does not adopt or delete user bottles.

`GamesVolumeStore` enumerates writable local volumes, displays free/total space, stores a bookmark
and volume UUID, and refuses to resolve an installation root through a different disk at the same
mount path. A real temporary-file check verifies write access. Folder creation and the write check
use cancellable, timed child commands because filesystem writes can wait for macOS permission UI.
This keeps the same app's permission requirement; it does not grant or bypass access.

`./scripts/test.sh` passed **59 tests**: 32 package tests and 27 app tests. Two additional opt-in
integration tests are skipped in the ordinary run. New app tests cover onboarding navigation,
volume persistence, a template failure followed by retry, display callbacks/preferences and skipping
setup without inventing an installation. Service tests cover restart reuse, ownership rejection,
license error mapping/redaction, symlink replacement, bookmark round trips and wrong-volume rejection.

The opt-in real-platform command passed:

```sh
BIGSCREEN_CROSSOVER_TEMPLATE_PROBE=1 swift test --package-path Packages/BigScreenKit \
  --filter CrossOverRuntimeTests.testRealCrossOverTemplateWhenRequested
```

It created a unique probe template, verified the configuration, executed
`cmd.exe /c echo BIGSCREEN_TEMPLATE_READY` through `cxstart --no-gui --wait-children`, reconstructed
ready state from disk, and deleted only that marked probe bottle. The test took 17.554 seconds.
No missing-executable test was sent to CrossOver; that known hang is covered by the earlier probe.

## Native UI and the permission-wait fix

Twenty-two native screens were captured at 1280×720 logical size in `.build/setup-ui/`. Pairing,
display, volume, preparation, failure and ready states were added to the existing snapshot harness.
The pairing illustration highlights Share and PS. The headings, volume capacity bars and preparation
panel were compared to designer boards 2e/2g/2h. Sign-in snapshot QR codes remain non-authenticating
fixtures. Live authentication challenges were not captured.

The first live keyboard run reached the actual volume list, but the original in-process write check
stalled in `open()` while macOS displayed a removable-volume access prompt. A process sample and
the system alert confirmed the cause. No permission was granted. The implementation was changed to
show the access wait, offer Cancel and use bounded child commands for the filesystem write check.

The subsequent live run exercised pairing → display choice → skip account → VM volume access wait
→ cancel → choose another drive → internal games folder → real template preparation → ready → Home.
Cancellation settled and the next volume choice succeeded. Native screenshots record the wait,
cancellation recovery and ready screen. The selected folder is `~/Games/GameNative`; the live
`gn-template-1` is now prepared and retained for future installs. The catalog records setup completion
and the selected display. No account was approved and no game was downloaded or launched.

The final build and code-signature verification passed. A native restart check verifies that setup
stays completed and Settings restores the selected folder and ready CrossOver template.

## Remaining acceptance

The external VM drive is HFS+, and macOS requires the user's removable-volume approval before the
app can write there. The internal-disk path and permission-wait cancellation are verified; external
write/install/reconnect behavior remains unverified. Fullscreen switching/disconnect recovery across
the user's displays, DS4 hardware traversal of these new screens, actual expired/unlicensed CrossOver,
and signed-in first-run timing still need acceptance checks. License failure mapping currently has
fixture evidence and a successful startup check on the installed runtime.

Template receipts and failures live under `Application Support/Big Screen/runtime`. General in-app
log browsing/rotation still needs completion. A damaged partial template whose ownership cannot be
proved is retained with an error; automatic repair of that case remains pending. Per-game clone/
prerequisites, installation/resume, launch/session supervision, saves and the exit overlay are also
unfinished v1 work.
