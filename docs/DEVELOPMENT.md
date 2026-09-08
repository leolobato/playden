# Developing Big Screen

The [root README](../README.md) covers player setup, controls, current features and the roadmap.
Run the commands below from the `big-screen` repository root.

**Current checkpoint:** development is paused at the user's request, with Big Screen and the
test game closed. Read [the next-session handoff](NEXT_SESSION_HANDOFF.md) before resuming.
The latest quit-confirmation implementation passes 137 app tests and the signed build; complete
live shutdown and focus validation are still open. Do not automatically run the app or tests
that take over the desktop while the user is using the Mac.

## Source layout

```text
GameNative/
├── big-screen/
└── GameNative-macos/
    └── swift/
```

`Packages/BigScreenKit` depends on `../../../GameNative-macos/swift`. The tested sibling revision is
**`608a619ee02e0a56ca223dd732d807b013330658`**, or a descendant retaining its APIs. It includes
Steam license acquisition dates as well as injected auth/key storage, bounded CM operations,
package entitlement lookup, Cloud transfers, verified resumable downloads and preparation fixes.
The sibling's current `main` does not yet contain all of those APIs; a checkout of `main` alone
is not the tested dependency. Preserve unrelated work when selecting a compatible checkout.

For a fresh sibling checkout with no local work, select the tested revision with:

```sh
git -C ../GameNative-macos switch --detach 608a619ee02e0a56ca223dd732d807b013330658
```

The supplied Steam interface fix is integrated into the sibling's main history (`9ce9f16`) and
its active dependency history (`13312ff`). The active revision above also includes later settings
preservation and acquisition-date work. See [interface validation](validation/2026-09-08-steam-interfaces.md)
and [settings preservation](validation/2026-09-08-steam-settings-preservation.md).

## Build and run

Build prerequisites: Apple Silicon, Xcode 26.3 / Swift 6, XcodeGen, and Homebrew xz, zstd, LLVM and
LLD. Select the full Xcode installation with `xcode-select` if your machine currently uses only
the Command Line Tools package. The deployment target is macOS 15; live execution has been
checked on macOS 26.6.2 with CrossOver 26.2.

```sh
brew install xcodegen xz zstd llvm lld
./scripts/build.sh
./scripts/run.sh
./scripts/run.sh --windowed
./scripts/run.sh --preview
```

The build embeds compression libraries and the Windows display helper. The staged app passed
[minimal-environment validation](validation/2026-09-08-minimal-environment.md): Steam Cloud access
and an A Short Hike launch with no development-shell variables or Homebrew library paths.
Preview still requires the sibling package at build time,
but does not use Steam credentials, CrossOver or game files at runtime.

`project.yml` is the project source of truth. Open `BigScreen.xcodeproj` in Xcode; regenerate with
`xcodegen generate` after adding files or changing targets/resources. Build and test scripts do this.

`run.sh` stages a verified copy at `~/Library/Application Support/Big Screen/Run/Big Screen.app`.
It requests a normal quit before replacing that copy and refuses replacement if shutdown does
not complete. Never replace the signed bundle under a running game or force-quit the launcher
just to stage a build. Downloads and sessions currently run in-process.

## Signing and permissions

Scripts reuse an available Apple Development certificate and cache the selection in
`.build/signing-identity`. Set `BIGSCREEN_CODE_SIGN_IDENTITY` to select another existing identity;
`-` selects ad-hoc signing. No certificate is created or imported by these scripts.

Without an Apple Development certificate, scripts fall back to ad-hoc signing. Rebuilds can
then require Keychain approval again. Moving an existing sign-in to development signing can
also require an initial approval. The app never asks for or stores the Mac login password.

The app runs **without App Sandbox**. macOS privacy and Keychain permissions still apply.
The stable launch location avoids Wine loading bundled helpers from protected Documents/Desktop
folders, and avoids Xcode replacing a running bundle during builds or tests. Repeated prompts
are not resolved by disabling App Sandbox again.

## Runtime and storage

CrossOver 26.x supplies the runtime. Big Screen prepares an owned `gn-template-1` Windows 10
64-bit template with MSync and D3DMetal, then clones an owned bottle for each game. It rejects
unowned/conflicting runtime locations. A missing per-game bottle is recreated and source
preparation must finish before launch; supported Cloud saves are then restored.

| Data | Location |
|---|---|
| Live catalog | `~/Library/Application Support/Big Screen/catalog.sqlite` |
| Preview catalog | `~/Library/Application Support/Big Screen/Preview/catalog.sqlite` |
| Per-game logs | `~/Library/Application Support/Big Screen/logs/` |
| Setup progress and errors | Live profile's `runtime/` directory |
| Artwork | `~/Library/Caches/GameNative BigScreen/artwork/` |
| CrossOver bottles | `~/Library/Application Support/CrossOver/Bottles/` |
| Game files | Selected writable games volume |
| Steam credentials | Keychain service `com.gamenative.bigscreen.steam` |

Games-volume selection defaults to `/Volumes/VM/GameNative/games` when writable and present,
otherwise `~/Games/GameNative`. The choice stores volume identity and a bookmark. Changing the
preference affects new installs; it does not move existing games. Runtime space and games-drive
space are checked separately.

Credentials have no file fallback. Passwords live only for the current sign-in attempt. Sign-out
clears credentials and cached ownership while retaining local edits, installation records and
local saves. Cloud attachment and pending transfers remain account scoped.

The Barlow/Barlow Condensed fonts include their OFL licenses. The pinned bundled Steamless
resources, hashes and licensing constraints are documented in [STEAMLESS.md](STEAMLESS.md).
Distribution and notarization are outside the current v1 scope.

## Tests and visual review

```sh
./scripts/test.sh
./scripts/snapshot.sh --snapshot-reduced-motion
BIGSCREEN_SNAPSHOT_DIR="$PWD/.build/screenshots-4k" ./scripts/snapshot.sh --snapshot-width 3840 --snapshot-reduced-motion
# A focused capture:
BIGSCREEN_SNAPSHOT_DIR="$PWD/.build/retry-ui" ./scripts/snapshot.sh --snapshot-screens notification-focused,logs-retry --snapshot-reduced-motion
# SwiftUI-only review when window capture is unavailable:
BIGSCREEN_SNAPSHOT_DIR="$PWD/.build/offscreen" ./scripts/snapshot.sh --snapshot-offscreen --snapshot-screens home,library --snapshot-reduced-motion
```

Snapshots use sample data and isolated catalogs. Authentication fixtures contain a non-authenticating
QR example. They never launch games. Native window capture needs Screen Recording permission for
the launching terminal; offscreen rendering does not exercise `NSViewRepresentable` content such
as the game action strip and log text viewport. Inspect native captures for those controls.

Tests cover focus and modal navigation, input repeat, persisted catalogs, identity-sensitive
retries, downloads and install checkpoints, runtime supervision, save mapping and Cloud recovery.
Optional live CrossOver probes require explicit configuration; a skipped integration test does
not satisfy the release gate. Full controller/TV flows and measured 600+ title frame pacing
remain separate acceptance work.

Run build, test, snapshot and app-replacement operations sequentially. For real game checks,
verify active sessions and Cloud work before restarting the app. Use the owned game's exact
process-start identity and window ID for input/capture; do not target a game by title alone.
Bare CGEvent injection does not trigger the registered global Shift–Home hotkey in the current
test environment; System Events does. See [current shortcut evidence](validation/2026-09-08-failure-retry-controls.md).

## Implementation references

- [PRD](prd/README.md) and [delivery/acceptance plan](IMPLEMENTATION_PLAN.md)
- [Design guidance](design/README.md)
- [A Short Hike uninstall/reinstall Cloud journey](validation/2026-09-08-uninstall-live-restore.md)
- [Missing-runtime recovery and remote save readback](validation/2026-09-08-live-runtime-cloud-recovery.md)
- [Steam acquisition sorting](validation/2026-09-08-steam-acquisition-dates.md)
- [Per-title prerequisite preparation](validation/2026-09-08-prerequisites.md)
- [Failure and log retry controls](validation/2026-09-08-failure-retry-controls.md)

The sibling `GameNative-macos` also contains a separate VM runtime. `GameNative-android` is the
reference for existing Android behavior and future per-game configuration interoperability.
