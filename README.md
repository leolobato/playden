# Big Screen

A living-room launcher for Windows games on a Mac: a TV-sized native SwiftUI/AppKit interface,
controlled with a gamepad, with Steam library integration and CrossOver game installation in progress.

Normal launches use your local catalog. Steam QR sign-in, password/Steam Guard fallback, Keychain
credential storage, progressive library refresh and offline cached browsing are connected. Favorites,
hidden games, collections and compatibility notes persist independently of Steam refreshes.
First run includes controller pairing guidance, display choice, a writable games-volume picker and
CrossOver template preparation with progress, retry and a browse-without-setup path.
**Game installation and launching are still being implemented.**

Use `--preview` for the designer's sample library and simulated Downloads queue. Preview edits use
an isolated database; install/uninstall confirmations only change preview state.

## Build and run

Requires Xcode 26.3 / Swift 6, XcodeGen, Homebrew xz/zstd (`brew install xcodegen xz zstd`), and an
Apple Silicon Mac. Check out the sibling `../GameNative-macos` with commit `b54c993` or its descendant
containing injected authentication storage and verified chunk-resume downloads. The local Swift package uses that checkout.
The deployment target is macOS 15 because of the bundled compression libraries; actual execution
has currently been checked on macOS 26.6.2. The build embeds xz/zstd in the app, so running the built
app does not require Homebrew's library paths.

```sh
./scripts/build.sh
./scripts/run.sh
# Optional windowed presentation or isolated design preview:
./scripts/run.sh --windowed
./scripts/run.sh --preview
```

Open `BigScreen.xcodeproj` to work in Xcode. `project.yml` is the project source of truth; regenerate
with `xcodegen generate` after changing targets or resources. The preview does not require a Steam
account or CrossOver; building either mode requires the sibling package.

CrossOver 26 or newer is required for game runtime setup. Big Screen creates only its managed
`gn-template-1` Windows 10 template, with MSync and D3DMetal enabled, and checks Windows startup.
It refuses an existing unowned bottle. Setup can be retried in Settings → Library → Runtime.
Games-volume selection prefers `/Volumes/VM/GameNative/games` when that writable volume is present,
otherwise `~/Games/GameNative`. It stores a volume identity and bookmark; choosing another drive
does not move existing games. Setup progress and failures are retained under the live profile's
`runtime/` folder. Template setup is separate from installing or verifying an actual game.

The Barlow/Barlow Condensed fonts and their OFL licenses are bundled. Steam artwork loads over the
network on first use and is cached in `~/Library/Caches/GameNative BigScreen/artwork/`. Missing art
shows a title placeholder. Local edits and preferences are stored separately in
`~/Library/Application Support/Big Screen/catalog.sqlite` (live) and
`~/Library/Application Support/Big Screen/Preview/catalog.sqlite` (preview). Tests and snapshots use
isolated in-memory catalogs. Authentication tokens use the macOS Keychain service
`com.gamenative.bigscreen.steam`, with no credential-file fallback. Passwords are kept only for the
current sign-in attempt. Signing out clears credentials and cached Steam ownership while retaining
local edits and installation records. The preview does not access account credentials or game files.

## Navigation

| Keyboard | Controller | Action |
|---|---|---|
| Arrows | D-pad / left stick | Move focus |
| Return / Escape | Cross / Circle | Open or select / back |
| Tab / Shift-Tab, `[` / `]`, Command-1…4 | L1 / R1 | Change tabs |
| F / T | Square / Triangle | Favorite / context menu |
| O | Options | Library sort/filter sheet |
| `/` | Touchpad click | Search keyboard |
| Page Up / Page Down | L2 / R2 | Move two grid rows |
| Home | PS | Return to Home |
| Control-Command-F | — | Toggle fullscreen |
| Command-Q | — | Quit Big Screen |

Type normally in search, collection names or compatibility notes, or navigate the on-screen keys.
While editing, L1/R1 (Tab/Shift-Tab) moves the text cursor, Square deletes, Triangle inserts a space,
and Options switches symbols. Select Done to save; Circle/Escape cancels collection/note drafts.
Command-Return finishes text entry from a physical keyboard. Password and Guard fields are masked.
Use More on a collection in the Library rail to rename, pin to Home, or delete it. On Downloads,
More opens pause/cancel/reorder actions for the selected row. Mouse clicks are also supported.

DS4 foreground input has been confirmed on hardware by the user. Background exit-overlay handoff
remains unverified. Focus drives scrolling in Home, Library and Downloads; rapid Home navigation
waits 400 ms before crossfading its ambient artwork. Game details fade in with a short upward motion.
Settings → Display → Reduced motion disables these transitions. Footer hints switch to keyboard
shortcuts when you use the keyboard, and back to gamepad glyphs when you use the controller.

Sort & Filter has grouped chips for all four sort orders, installation, genre, controller support
and compatibility; Source appears when multiple sources are present. The sheet scrolls with focus,
updates the result count immediately, and persists selections. Reset clears refinements and sorting
while preserving the current collection and search. Browse all games recovers an empty result.

Settings → Controller → Button test shows live button presses, both sticks, and trigger pressure.
Press a control on another connected pad to switch the readout. Short Circle/B presses are testable;
hold Circle/B for 1.2 seconds to close, or press Escape. Launcher actions stay trapped in this screen.
Hardware validation of this new diagnostic screen is still pending.

## Validation

```sh
./scripts/test.sh
./scripts/snapshot.sh
# Also check scaled window layouts:
BIGSCREEN_SNAPSHOT_DIR="$PWD/.build/screenshots-720p" ./scripts/snapshot.sh --snapshot-width 1280
```

The test suite covers logical grid movement/repeat and native presentation-state interactions
(modal focus, navigation memory, search, collection/note editing, Unicode text cursors,
queue reordering, cancellation and focus-driven scrolling/empty-state recovery). Catalog tests cover
SQLite reopen/rollback, source refresh/logout retention, job reconstruction, exact session accounting,
and credential redaction. Account tests cover Keychain isolation, cancellation/logout races, metadata
mapping, masked credential entry and stable focus during refresh. See
[Steam/account validation](docs/validation/2026-09-07-steam-account.md),
[setup/runtime validation](docs/validation/2026-09-07-setup-runtime.md),
[controller/filter and download-resume validation](docs/validation/2026-09-07-controller-filters.md), and [recorded foundation/platform evidence](docs/validation/2026-09-07-foundation.md).

Snapshots are actual native window captures in `.build/screenshots/`. They use a 1920×1080 logical
canvas (pixel dimensions follow the display backing scale), a fixed clock, and the same artwork
cache as the app. Window capture requires existing macOS Screen Recording access for the launching
terminal; the script fails with an explicit error if it is unavailable. Reference screenshots live
in `docs/design/screenshots/`. Snapshot capture never launches a game. Sign-in captures contain a non-authenticating example QR,
never a live challenge or account credentials.

## Product and delivery

- [PRD](docs/prd/README.md)
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md)
- [Designer guidance and chosen mockups](docs/design/README.md)

Related repositories, siblings under `../`:

- `GameNative-macos` — Swift Steam layer (`SteamCore`) and a separate VM runtime.
- `GameNative-android` — upstream Android app whose per-game config schema informs v2 properties.
