# PlayStation symbols and mouse visibility — 7 September 2026

PlayStation Cross, Circle, Square and Triangle now use shared vector paths with optical size
adjustments and a common stroke weight. This replaces mismatched font characters in footer hints,
action hints, the pairing illustration and controller-test buttons. Shapes have accessible names.
Keyboard and generic controller labels continue to render as text.

The launcher no longer maintains a persistent NSCursor hide/unhide counter. Navigation uses
`setHiddenUntilMouseMoves(true)`; mouse movement, button presses, dragging and scrolling reveal
the cursor. Activation and game handoff restore it. Mouse events pass through to existing controls;
there is no mouse capture, cursor warping or pointer lock in the app.

Validation:
- 52 app tests passed (`/tmp/bigscreen-input-polish-tests.log`); signed build verified by run.sh.
- Inspected native 1080p and 4K snapshots in `.build/input-polish-ui/`: Home/Library with PlayStation
  hints, the keyboard's Square/Triangle/Circle hints and the controller-test illustration/buttons.
- Live app check switched keyboard → stationary mouse click → keyboard → mouse movement, and
  reopened the app after hiding it. Captured only a small rectangle inside Big Screen's Settings
  tab, once with the cursor and once without it. The pixel difference was present after movement,
  clicking without movement, one second after clicking, and reactivation; it was zero after each
  keyboard-navigation step. Captures: `.build/cursor-ui/0...7-{plain,cursor}.png`.
- Other applications were not captured during focus loss. The physical DS4/game handoff remains
  part of the broader manual acceptance run.

The attempted deprecated CGCursorIsVisible probe is unavailable in the macOS Swift SDK, so cursor
visibility evidence comes from the native captures, not that API.
