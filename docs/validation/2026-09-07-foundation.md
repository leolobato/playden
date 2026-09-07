# Foundation and CrossOver observations — 2026-09-07

This records partial v1 evidence. It does not satisfy the real-game, controller handoff, install,
or release acceptance gates in the PRD.

## Platform

- Hardware identifier: Mac17,9; Apple Silicon; 48 GiB RAM.
- macOS 26.6.2 (25G83).
- Xcode 26.3 (17C529), Swift 6 language mode; project deployment target remains macOS 14.
- CrossOver 26.2 at `/Applications/CrossOver.app`.
- `/Volumes/VM` is mounted. Filesystem suitability, free-space accounting and volume identity
  handling still need validation in the storage service.
- DS4 foreground navigation was confirmed by the user earlier. No unattended test here proves
  background PS-hold delivery, overlay input suppression, gameplay, or TV viewing distance.

## Catalog and app persistence

`CatalogStore` uses GRDB 7.11.1, pinned in `Packages/BigScreenKit/Package.resolved`. The app links the
Catalog product. Migrations create source metadata, local edits, collections/membership, preferences,
install records, jobs and sessions. Each public mutation is a SQLite transaction.

Nine catalog tests verify file-backed reopening, invalid-operation rollback, stable source/game
identity, metadata merge ordering, retained offline installs and local edits after logout, exact
session checkpoint accounting, reconstructed job stages/manifests/pause reasons, installation commit,
and redaction before failure persistence. These tests prove stored contracts, not working download
resume, filesystem cleanup or CrossOver process supervision.

Four app persistence tests verify model recreation, deletion without fixture reseeding, production
catalog isolation from fixtures, and recovery from rejected writes. Together with the existing five
focus/input and sixteen interaction tests, 34 tests pass. The Xcode app builds successfully.

An actual native process test changed Hades' favorite with keyboard input, quit, relaunched, and
verified the saved value. It then restored the original favorite. The rendered Home screen was
captured after relaunch at `.build/v1ui/persisted-home.png`.

The interactive design preview stores local edits and preferences in
`~/Library/Application Support/Big Screen/Preview/catalog.sqlite`. Tests and snapshots use isolated
memory stores. Production model injection uses `preview: false` and never seeds fixtures. The
interactive app still defaults to the preview until the Steam/first-run service wiring is complete.
Preview queue/install status remains simulated and is deliberately not written as real installations.

## CrossOver command probe

Run `./scripts/probe-crossover.py`. It creates random `gn-probe-<uuid>-template/game` bottles, refuses
existing paths, writes ownership markers, and cleans up only matching probe-owned bottles. Per-stage
output and structured results go into `.build/crossover-probe/<uuid>/`.

Observed twice:

| Operation | Result |
|---|---|
| `cxbottle --bottle <template> --create --template win10_64` | Exit 0; 10.8–12.7 seconds |
| Creation params `EnvironmentVariables:WINEMSYNC=1`, `EnvironmentVariables:CX_GRAPHICS_BACKEND=d3dmetal` | Both verified in the resulting bottle configuration |
| `cxbottle --bottle <game> --copy <template>` | Exit 0; 2.8–7.0 seconds |
| `cxstart --bottle <game> --no-gui --wait-children cmd.exe /c "echo BIGSCREEN_PROBE_OK"` | Exit 0 and expected Windows command output |
| Same launch flags with nonexistent `Z:\bigscreen-no-such-file.exe` | Did not terminate at 120 seconds; reproduced with a 15-second bound |
| `cxbottle --bottle <owned probe> --delete --force` for both bottles | Exit 0; both directories absent afterward; no cleanup errors |

The probe exits nonzero on the missing-executable failure. This is retained negative evidence,
not a passing platform gate. Its second run records `timedOut: true` and preserves the output file.
Evidence directories: `608fa6a4340842fc964065bfbb6b7d4e` and `92519cf235e242e6b839efc8df791688`.

Consequences for Runner implementation:

- Validate the executable and working directory before calling CrossOver. `--no-gui` is not evidence
  that every failure returns promptly or that no other Windows UI can appear.
- Keep delayed launch controllable and retain the failing stage/output. A wrapper waiting forever
  must not strand controller navigation.
- Supervise owned bottle processes and validate scoping before stop/delete. Successful probe cleanup
  does not establish graceful close, child handoff, or isolation while an unrelated game is running.
- Successful `cmd.exe` execution demonstrates usable command execution on this installation. It does
  not establish licensing duration, game compatibility, graphics performance, saves or controller support.
