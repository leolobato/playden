# Home row identity and focus — 8 September 2026

Requirements: PRD 03 FR-FOCUS-3/4 and PRD 04 FR-HOME-1, FR-COL-1.

Home used the displayed row name to recognize Continue Playing. A pinned user collection with
that name was incorrectly limited to 15 games and given a Library card. Row focus and horizontal
offsets were also remembered by position, so inserting Downloading Now or removing/reordering
collections could transfer another row's selection to the current collection.

Built-in rows now have distinct identities; collection rows use their collection UUID. Only the
built-in Continue Playing row is capped and receives the Library card. Before changing Home's
contents, the model captures each row's selected game (or Library card) and viewport by identity.
Afterward it restores surviving children and keeps them visible; a removed child falls back to
the adjacent available item, and a removed row to a nearby surviving row's own remembered child.
Catalog refresh batches game, collection and installation updates before restoring Home focus,
including when tabs or another screen have focus. Rendered rows and cards also use stable IDs.

Validation:

- Six new app regressions cover built-in/collection name collisions, row insertion/removal,
  collection reorder/rename, game reorder/removal, tab switches, an empty Home, a shrinking
  Continue Playing row while its Library card is selected, persisted catalog refresh, and a
  batch in which a collection temporarily has no surviving members.
- Targeted navigation/persistence/session suite: 35 tests passed before the final batch-update
  regression. `/tmp/bigscreen-home-identity-tests.log`. The same script passed 241 package XCTest
  tests (6 existing skips) and 5 Swift Testing tests.
- Final complete app suite: 108 tests, no failures.
  `/tmp/bigscreen-home-identity-all-app-tests.log`.
- Signed build and stable-bundle staging/launch passed. No unfinished game sessions or Cloud
  claims were present before staging. `/tmp/bigscreen-home-identity-build.log`,
  `/tmp/bigscreen-home-identity-run.log`.
- Four Home fixtures rendered at 1920×1080 and 3840×2160 with reduced motion: default Home,
  final Library card, final item in a 720-game collection, and final item in a 40-game user
  collection named Continue Playing. Artifacts: `.build/home-identity-1080/` and
  `.build/home-identity-4k/`; logs `/tmp/bigscreen-home-identity-render.log` and
  `/tmp/bigscreen-home-identity-render-4k.log`.
- Visually inspected the 1080p Library-card and name-collision fixtures, plus the 4K 720-game
  collection endpoint. The selected card/ring and title remain visible above the legend.
  Also rendered/inspected the 1080p collision fixture with normal focus scale in
  `.build/home-identity-motion/`. These are offscreen layout checks, not physical DS4 input or
  compositor frame-pacing measurements.

No live game preparation, launch, save modification or Cloud transfer was performed for this
checkpoint. The remaining physical acceptance gates remain open.

After the desktop became available, the signed app's real Home was captured with the user's
Steam library loaded. PID-targeted keyboard input then exercised Home → Up to tabs → Right to
Library → Down to content, returned Home, moved to the final Library card, and opened the full
Library. Accessibility assertions and owned-window captures passed:
`/tmp/bigscreen-home-identity-live.log`, `.build/home-identity-live/`. No game was launched or
collection changed. This adds live keyboard/window evidence; it does not prove physical DS4 input.
