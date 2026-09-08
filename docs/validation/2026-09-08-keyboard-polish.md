# Keyboard and modal polish — 8 September 2026

The on-screen keyboard now moves vertically to the closest key center and retains its horizontal
position through the wide Space and Done keys. Horizontal movement, pointer selection and a symbol
layout change reset that preferred position. Keyboard/controller focus remains inside the editor.

Footer hints follow the active input device in the editor, Steam sign-in and setup. Shoulder buttons
have separate glyphs, physical keyboard users see cursor/commit shortcuts, and long input truncates
before the cursor so recently typed text remains visible. Opening a panel suppresses the underlying
page's focus ring.

Validation:
- All 89 app tests passed, including the new keyboard navigation regression and existing account
  interaction tests. `/tmp/bigscreen-keyboard-polish-app-tests.log`.
- Signed build passed. `/tmp/bigscreen-keyboard-polish-build.log`.
- With zero unfinished sessions and zero Cloud claims, staged and launched the signed app from
  its stable Application Support bundle using normal quit handling. `/tmp/bigscreen-keyboard-polish-run.log`.
- Seven fixture screens rendered at both 1920×1080 and 3840×2160; the latter run used the new
  `--snapshot-reduced-motion` option. Files are in `.build/keyboard-polish-1080/` and
  `.build/keyboard-polish-4k/`. Keyboard, PlayStation keyboard, long input, password sign-in and the
  bottom of the library filter panel were visually inspected. Text, glyphs, cursor and focused
  controls are visible, with one active focus ring.
- Snapshot setup now uses one model per screen and applies the requested motion setting to it.

These are offscreen layout checks. SwiftUI ImageRenderer omits the game detail page's native
scrollable action strip; it cannot establish live animation quality or controller hardware behavior.
Live-window and physical DS4 acceptance remain open while the desktop is locked.

The current SteamCore integration was also rechecked: main contains `9ce9f16`, the active local
dependency contains `13312ff`, and Oniken's `DATA/steam_settings/steam_interfaces.txt` still has all
17 entries including `STEAMUSERSTATS_INTERFACE_VERSION011`. Exact crash-action replay remains open
in the [interface validation record](2026-09-08-steam-interfaces.md).
