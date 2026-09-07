# Controller, library filters and download resume — 2026-09-07

This checkpoint continues v1 UI work. It does not complete v1 or prove a real game install/play/save
journey. The product remains **Big Screen**; the legacy artwork-cache directory is retained.

## Native UI

- Settings → Controller now opens a live button test: device names, face/D-pad/shoulder/system
  buttons, stick clicks and positions, and analog trigger pressure. Input from another connected
  pad selects its readout. Pressed controls and previously tested controls have separate states.
- Diagnostic input cannot navigate the launcher. A short Circle/B press is testable; holding it
  for 1.2 seconds closes the screen. Escape and the mouse Close action remain available when the
  controller disconnects. Disconnect clears live values and cancels the pending hold.
- Keyboard input switches the footer to actual keyboard shortcuts, including Tab, Escape, O and
  slash. Controller input restores gamepad glyphs. DualSense receives PlayStation glyphs and
  touchpad mapping alongside DS4.
- Sort & Filter uses the designer's 640-point sheet, grouped 54-point chips, accent focus,
  compatibility dots and result count. Directional movement follows wrapped rows; the sheet
  scrolls with the highlighted chip. Reset remains reachable at the bottom.
- All four sorts are implemented. Installation, genre, controller support and compatibility
  combine with the active collection and search; Source appears for multiple sources. Missing
  controller metadata remains Unknown. Disconnected installations count as installed.
- Sort and refinements persist. Reset preserves collection/search; Browse all games clears
  refinements and recovers an empty result. Seeding preview data preserves existing preferences,
  including setup and display selection.

## Validation

`./scripts/test.sh` passed: **70 passed, 2 optional probes skipped** (33 XCTest package cases,
including the two skips; 5 Swift Testing focus cases; 34 app cases). The new tests exercise
controller hold/release/disconnect, per-device diagnostic history, analog clamping, modal input
trapping, every sort, composed filters, wrapped-chip scrolling, empty-result recovery and persisted
preferences. The first persistence run exposed preview seeding replacing setup preferences; the
implementation was fixed and the complete suite passed afterward.

The Debug app builds and passes `codesign --verify --deep --strict`. Native captures at 1280×720
logical size are in `.build/controller-ui/` and `.build/filter-ui/`. The controller fixture,
disconnected screen and filter sheet at both ends were visually reviewed against the design
tokens and `docs/design/screenshots/2b-library-filters.png`.

An actual keyboard-event run opened the filter sheet, navigated down to Reset and back up,
navigated Downloads down/up, opened the controller test, confirmed Tab/Home stayed trapped,
and closed back to Settings using Escape. Current-build captures are
`.build/filter-ui/native-filters-{top,bottom,return}.png`, `native-download-{down,up}.png`, and
`native-controller-test.png`. The active controller illustration capture uses synthetic values;
hardware validation of the new diagnostic view, multiple pads and DualSense remains pending.
The user's earlier DS4 foreground navigation confirmation remains the hardware evidence.

## SteamCore dependency

Sibling commit **`b54c993`** adds verified chunk checkpoints and replaces the former size-only,
whole-file resume path in `DownloadEngine`. The downloader syncs chunk bytes before atomically
recording completion, verifies retained ranges on reopen, verifies complete files before atomic
replacement, and can reuse a caller-persisted manifest. Manifest path validation and directory
descriptor operations prevent writes through parent symlinks; an exclusive destination lease
prevents concurrent writers. CDN requests have timeouts; chunk retries preserve cancellation.

The targeted SteamCore suite reports 26 cases with one optional fixture skipped and no failures.
Nine new tests cover partial-file reopen, corrupted retained ranges, same-size corrupt originals,
preserving an existing file after interrupted replacement, a changed pinned manifest, failed
whole-file digest retry, invalid paths, parent symlinks, destination locking, no servers, checksums
and empty files. They use synthetic bytes, with no account or game download.

This proves durable checkpoint reopen in fixtures. Abrupt process-kill resume, real Steam depot
download, authenticated CM cancellation/timeouts, aggregate job scheduling and app installation
integration remain open. The live app still reports installation as unfinished.

Protocol references: [SteamKit chunk validation](https://raw.githubusercontent.com/SteamRE/SteamKit/master/SteamKit2/SteamKit2/Steam/CDN/DepotChunk.cs)
and [manifest hash fields](https://github.com/SteamRE/SteamKit/blob/master/SteamKit2/SteamKit2/Types/Manifest.cs).
