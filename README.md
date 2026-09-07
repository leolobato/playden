# GameNative Big Screen

A living-room launcher for Windows games on a Mac: a TV-sized native SwiftUI/AppKit interface,
controlled with a gamepad, with Steam and CrossOver integration planned.

The first implementation is a **design preview**, matching the [designer handoff](docs/design/README.md).
Home, Library, the split game page, Downloads, Settings, search keyboard, filters and context panels
use isolated sample data. Favorites, hiding and compatibility edits last for the preview session.
**Steam authentication, installation and game launching are not connected yet.**

## Build and run

Requires Xcode 26.3 / Swift 6, XcodeGen (`brew install xcodegen`), and an Apple Silicon Mac.
The deployment target is macOS 14; actual execution has currently been checked on macOS 26.6.2.

```sh
./scripts/build.sh
./scripts/run.sh
# Optional fullscreen presentation:
./scripts/run.sh --fullscreen
```

Open `BigScreen.xcodeproj` to work in Xcode. `project.yml` is the project source of truth; regenerate
with `xcodegen generate` after changing targets or resources. The preview does not require Steam,
CrossOver or the sibling checkout. Its eventual Steam integration will use the sibling package.

The Barlow/Barlow Condensed fonts and their OFL licenses are bundled. Steam artwork loads over the
network on first use and is cached in `~/Library/Caches/GameNative BigScreen/artwork/`. Missing art
shows a title placeholder. No login credentials or game files are accessed by the preview.

## Navigation

| Keyboard | Controller | Action |
|---|---|---|
| Arrows | D-pad / left stick | Move focus |
| Return / Escape | Cross / Circle | Open or select / back |
| `[` / `]` | L1 / R1 | Change tabs |
| F / T | Square / Triangle | Favorite / context menu |
| O | Options | Library sort/filter sheet |
| `/` | Touchpad click | Search keyboard |
| Page Up / Page Down | L2 / R2 | Move two grid rows |
| Home | PS | Return to Home |
| Control-Command-F | — | Toggle fullscreen |
| Command-Q | — | Quit preview |

Type normally while the search keyboard is open, or navigate its keys with the controller. Mouse
clicks are also available for development. Controller foreground mapping is implemented; physical
DS4 testing and background exit-overlay handoff are still unverified.

## Validation

```sh
swift test --package-path Packages/BigScreenKit
./scripts/snapshot.sh
```

Snapshots are actual native window captures in `.build/screenshots/`. They use a 1920×1080 logical
canvas (pixel dimensions follow the display backing scale), a fixed clock, and the same artwork
cache as the app. Window capture requires existing macOS Screen Recording access for the launching
terminal; the script fails with an explicit error if it is unavailable. Reference screenshots live
in `docs/design/screenshots/`. Snapshot capture never launches a game.

## Product and delivery

- [PRD](docs/prd/README.md)
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md)
- [Designer guidance and chosen mockups](docs/design/README.md)

Related repositories, siblings under `../`:

- `GameNative-macos` — Swift Steam layer (`SteamCore`) and a separate VM runtime.
- `GameNative-android` — upstream Android app whose per-game config schema informs v2 properties.
