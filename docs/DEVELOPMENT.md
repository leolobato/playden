# Developing Big Screen

The [root README](../README.md) covers player setup, controls, current features and the roadmap.
Run the commands below from the `big-screen` repository root.

The [development handoff](NEXT_SESSION_HANDOFF.md) and [validation notes](validation/)
record gameplay and controller acceptance work. Build and packaging checks do not replace
those live checks. Avoid tests that take over the desktop while someone is using the Mac.

## Source layout

```text
big-screen/
├── App/
├── Config/
└── Packages/
    ├── BigScreenKit/
    └── SteamKit/
```

All application and Steam library source is in this repository. `BigScreenKit` depends on
`../SteamKit`, whose `SteamCore` product includes authentication, entitlement lookup, metadata,
Cloud primitives, downloads and game preparation. No sibling checkout is required.
See [SteamKit](../Packages/SteamKit/README.md) for its tests, protocol generation and source provenance.

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

`build.sh` defaults to Debug, and `run.sh` always uses the Debug build. For an optimized local
Release build, run `./scripts/build-release.sh`. The verified bundle is revealed in Finder at
`DerivedData/Build/Products/Release/Big Screen.app`; quit Big Screen before copying it into
`/Applications`. See the [source installation instructions](../README.md#build-from-source-and-install).
Both configurations use the same signing selection and embed the runtime dependencies.
Use `./scripts/build-release.sh --no-open` to build without opening Finder.

The build embeds compression libraries and the Windows display helper. The staged app passed
[minimal-environment validation](validation/2026-09-08-minimal-environment.md): Steam Cloud access
and an A Short Hike launch with no development-shell variables or Homebrew library paths.
Preview uses the same in-repository packages,
but does not use Steam credentials, CrossOver or game files at runtime.

`project.yml` is the project source of truth. Open `BigScreen.xcodeproj` in Xcode; regenerate with
`xcodegen generate` after adding files or changing targets/resources. Build and test scripts do this.

`run.sh` stages a verified copy at `~/Library/Application Support/Big Screen/Run/Big Screen.app`.
It requests a normal quit before replacing that copy and refuses replacement if shutdown does
not complete. Never replace the signed bundle under a running game or force-quit the launcher
just to stage a build. Downloads and sessions currently run in-process.

## Bundle ID and signing team

Shared defaults live in [`Config/Build.xcconfig`](../Config/Build.xcconfig). To override them
locally without editing the generated Xcode project:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Edit `Config/Local.xcconfig` (ignored by Git):

```xcconfig
BIGSCREEN_BUNDLE_IDENTIFIER = com.yourcompany.bigscreen
DEVELOPMENT_TEAM = YOURTEAMID
```

The default bundle ID is `com.bigscreen.app` and the default team is empty. Both Debug and
Release use this configuration. The test bundle appends `.tests`; the run script reads the
built app's ID, and the distribution script derives the DMG signing identifier from it.
The scripts resolve `DEVELOPMENT_TEAM` through Xcode and select a matching local development
certificate. An explicit signing certificate must also match the configured team. A distribution
build still requires `BIGSCREEN_DEVELOPER_ID` to select its Developer ID Application certificate.
Command-line Xcode build settings can override xcconfig values when building directly with Xcode.

Changing bundle ID creates a separate Keychain service (`<bundle-id>.steam`) and can cause an
initial macOS credential-access prompt. The default Big Screen identity migrates the research
build's saved Steam credentials once; custom bundle IDs require their own Steam sign-in.
Existing catalog/settings storage, recorded game paths and CrossOver bottles are retained.
The legacy `.gn-download` checkpoint and `gn-template-1` bottle names remain on-disk compatibility
identifiers, not product branding. New games folders and the artwork cache use Big Screen names.

## Signing and permissions

Scripts reuse an available Apple Development certificate for the configured team and cache the selection in
`.build/signing-identity`. Set `BIGSCREEN_CODE_SIGN_IDENTITY` to select another existing identity;
`-` selects ad-hoc signing. No certificate is created or imported by these scripts.

With no team configured and no Apple Development certificate, scripts fall back to ad-hoc signing.
If a team is configured but its certificate is missing, the build reports an error; explicitly
set `BIGSCREEN_CODE_SIGN_IDENTITY=-` to opt into a local ad-hoc build. Rebuilds can
then require Keychain approval again. Moving an existing sign-in to development signing can
also require an initial approval. The app never asks for or stores the Mac login password.

The app runs **without App Sandbox**. macOS privacy and Keychain permissions still apply.
The stable launch location avoids Wine loading bundled helpers from protected Documents/Desktop
folders, and avoids Xcode replacing a running bundle during builds or tests. Repeated prompts
are not resolved by disabling App Sandbox again.

## Distribution builds

`scripts/distribute.sh` creates an Apple Silicon Release app and a drag-to-Applications DMG
for GitHub releases or other downloads. It requires the same source/build dependencies, an
installed **Developer ID Application** certificate with its private key, and Apple notarization
credentials. It never falls back to development or ad-hoc signing.

For local releases, store notarization credentials in macOS Keychain once. This command prompts
for the required values; do not put passwords in scripts or commit them:

```sh
xcrun notarytool store-credentials "big-screen-notary"
security find-identity -v -p codesigning
```

Select the full Developer ID Application name (or SHA-1) from that list, then build with an
explicit marketing version and positive integer build number. Source builds default to version
`0.1`, build `1`, configured by `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`project.yml`:

```sh
export BIGSCREEN_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export BIGSCREEN_NOTARY_PROFILE="big-screen-notary"
./scripts/distribute.sh 0.1 1
```

Alternatively, use an App Store Connect API key, including in CI. Import the Developer ID
certificate into the runner's Keychain first, and supply the private `.p8` file from a secret
store. The script accepts these variables instead of a Keychain profile:

```sh
unset BIGSCREEN_NOTARY_PROFILE
export BIGSCREEN_NOTARY_KEY_PATH="/path/to/AuthKey.p8"
export BIGSCREEN_NOTARY_KEY_ID="YOUR_KEY_ID"
export BIGSCREEN_NOTARY_ISSUER_ID="YOUR_ISSUER_UUID"
./scripts/distribute.sh 0.1 1
```

The issuer UUID is required for team API keys; omit it for individual API keys. A configured
Keychain profile takes precedence over API key variables. Keep private keys outside the repository.

The script validates the identity and notarization credentials, builds in
`.build/distribution/DerivedData`, enables hardened runtime, and signs the native libraries and
app with secure timestamps. It submits the app to Apple and staples the accepted ticket before
packaging it with an Applications shortcut. It then signs, notarizes and staples the DMG,
verifies signatures and tickets, and checks both the app and DMG with Gatekeeper. This follows
Apple's [signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
and [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

Only after every check succeeds does it place `dist/Big-Screen-0.1-1-arm64.dmg` at the final
output path. Upload that DMG to the GitHub release; the script does not publish it. Open the DMG
to install by dragging Big Screen into Applications, after quitting any running copy.
Notarization responses and Apple logs are retained under `.build/distribution/notarization.*`,
including on rejection. Review the logs for warnings and test the downloaded DMG on a clean Mac
before publishing a release. Increase the build number for subsequent builds of the same version.

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
| Artwork | `~/Library/Caches/Big Screen/artwork/` |
| CrossOver bottles | `~/Library/Application Support/CrossOver/Bottles/` |
| Game files | Selected writable games volume |
| Steam credentials | Keychain service `<bundle-id>.steam` (default `com.bigscreen.app.steam`) |

Games-volume selection defaults to `/Volumes/VM/Big Screen/games` when writable and present,
otherwise `~/Games/Big Screen`. The choice stores volume identity and a bookmark. Changing the
preference affects new installs; it does not move existing games. Runtime space and games-drive
space are checked separately.

Credentials have no file fallback. Passwords live only for the current sign-in attempt. Sign-out
clears credentials and cached ownership while retaining local edits, installation records and
local saves. Cloud attachment and pending transfers remain account scoped.

The Barlow/Barlow Condensed fonts include their OFL licenses. The pinned bundled Steamless
resources, hashes and licensing constraints are documented in [STEAMLESS.md](STEAMLESS.md).
The distribution workflow above handles signing and notarization; game compatibility and the
remaining acceptance checks are separate release requirements.

## Tests and visual review

To trace an installation failure with the installed Release app, quit Big Screen, then run
the diagnostic with the game's Steam app ID:

```sh
"/Applications/Big Screen.app/Contents/MacOS/Big Screen" --diagnose-install 1888160
```

It uses the app's saved sign-in to check authentication, package/depot entitlements and manifest
resolution without installing or launching a game. Output contains stages and numeric error
codes, not credentials, account identifiers, depot keys or signed URLs. An access-denied content
response is distinct from expired authentication and should not trigger another sign-in loop.

For a stall after manifest resolution, add `--download-probe-root /Volumes/YourDrive` to that
command. This opt-in check downloads at most eight chunks (8 MiB uncompressed), writes and
verifies them through the real downloader in a unique temporary folder on the selected drive,
then removes that folder. It never writes into an existing game installation.

Large depot files grow as chunks arrive rather than being preallocated. Download checkpoints
sync file data before atomically replacing the journal, in batches of 16 MiB or one second of
received chunks. Pause/error flushes the pending batch; resume revalidates every retained range.
Abrupt termination may redownload the last uncheckpointed batch. Bulk downloads use `fsync`
without per-chunk `F_FULLFSYNC` drive-cache flushes, which can stall external HFS+ drives.

Game details lazily request compressed depot sizes after a 300 ms navigation debounce. The
SQLite `download_sizes` cache is scoped by source, game and a hashed account identifier, with
public-English manifest IDs and a six-hour freshness window (15 minutes for unknown sizes).
Library refresh invalidates freshness while retaining the displayed value for offline use.
Install resolution supplies the precise manifest total; a later metadata estimate cannot replace
that precise value for the same manifest set. No CDN manifests or game chunks are fetched just
to show a metadata estimate, and missing compressed sizes remain unknown.

Download speed uses an eight-second sample window. Time remaining uses 30 seconds, waits for
ten seconds of samples, and updates at most every five seconds; stalls clear it immediately
once the speed window detects no transfer. The download card gives byte progress and speed
fixed column widths, uses tabular digits, and rounds time remaining to minutes.
Whole-file checks during downloading report file-local bytes checked, including reused files.
Resume checks also report progress across saved chunks, in file-offset order to avoid random
seeks. Rejected chunks count as checked but never as retained or freshly downloaded bytes.
The row shows verification progress and hides speed/ETA until downloading resumes. These
counters are transient and never advance downloaded bytes or the durable install stage.
Steam progress sequence numbers reject delayed callbacks; phase transitions publish immediately.
Rate windows restart after verification so disk-check time does not skew download estimates.
File reads release Foundation buffers per block to bound memory during large archive checks.
Before transferring a pinned install plan, Steam checks entitlement and fetches all selected
depot keys into the invocation's memory cache, then closes the CM control connection. CDN
downloads and resume checks do not depend on that connection surviving a long first depot.
Disconnected CM requests report a network failure rather than a malformed library response.

Steam install plans retain all eligible launch options, including descriptions, arguments and
working directories. Non-public `betakey` entries and unowned DLC options are excluded.
The per-game **Always use this** preference is stored in catalog edits; changing launch metadata
invalidates a remembered choice. Existing installations recover options from their saved Steam
metadata without a network request. A one-time choice remains active through runtime preparation
and Cloud review without replacing the installation's default launch spec.

```sh
python3 scripts/test-release.py
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
