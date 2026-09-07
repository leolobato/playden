# Home navigation and bounded recent games — 7 September 2026

Up from the first Home row now focuses the current top tab. Left/Right switches screens while
keeping focus in the tab bar; Down, Confirm or Back returns to content. The prior Home card and
horizontal offset survive tab changes. The same Up handoff works at the top of Library, Downloads
and Settings. Page-up stays in content. Game-specific actions are inactive while tabs are focused,
and the footer shows Switch tabs / Browse / Back.

Continue playing contains at most 15 games ordered by last played, followed by a Library card.
The card opens the full library, clearing search and filters. It is reachable with directional
navigation or the mouse; no game actions appear while it is selected. The row stops at that card
and can scroll back to its first game. The focus viewport keeps the last card's ring within the
5% TV safe area. Other Home rows retain their existing contents.

Validation:
- Package suite: 100 XCTest tests (3 existing integration skips) and 5 Swift Testing tests passed
  in `/tmp/bigscreen-home-navigation-tests.log`. The initial app compilation in that combined run
  failed because InputAction is not Equatable; changed the directional branch to pattern matching.
- All 55 app tests then passed (`/tmp/bigscreen-home-app-tests.log`). After adjusting the final
  card's right inset, all 13 LibraryInteractionTests passed (`/tmp/bigscreen-home-focused-tests.log`).
- Added coverage for tab focus, suppressed game actions, entering/restoring content, a 40-game
  recent list capped at 15 plus the Library card, right-edge clamping, safe-area scrolling,
  reconciliation while the Library card is selected, clearing filters, returning left, page-up
  behavior and reaching tabs from empty Home.
- Inspected native Home tab-focus and Library-card captures at 1080p and 4K in
  `.build/home-navigation-ui/` and `.build/home-navigation-ui-4k/`. The uninstall preview capture
  also confirms removal of the deferred Keep saves checkbox.
- Live signed app: Home → Up → Right → Down entered Library; Home → repeated Right reached the
  final Library card; Return opened All 538 games. Only launcher windows were captured, in
  `.build/setup-ui/home-{tabs-live,tabs-library-live,library-card-live,library-open-live}.png`.
  The initial helper's exact-label assertion missed macOS's combined rail labels containing
  counts; screenshots already showed the correct destination. Updated the assertion to match
  label prefixes and reran. Log: `/tmp/bigscreen-home-live-ui.log`.

The shared semantic action path is tested, and the live keyboard flow is verified. Physical DS4
acceptance remains part of the full v1 TV run. The updated signed app is running from its stable
Application Support bundle.
