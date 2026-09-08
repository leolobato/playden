# Downloads history dismissal — 8 September 2026

Completed, cancelled and failed jobs offer **Dismiss from history** in their keyboard/controller
action menu. The choice persists across restarts without deleting job diagnostics, changing
installation state or cancelling work. Failed jobs remain reachable from the game page; retries
and later failures appear again. Active, queued and paused work cannot be dismissed.

Catalog migration v4 stores presentation receipts for the reviewed job state. Dismissal compares
the complete reviewed job with durable state, rejecting stale menu actions. Filtering happens
after selecting each game's latest job, so dismissal does not reveal older entries. Focus moves
to the remaining row, or to the tabs when the list becomes empty. Context-menu titles now follow
the menu's game even when queue rows move, and keyboard users see ESC for Close.

## Validation

- Full suite: 186 package XCTest tests (4 integration skips), 5 Swift Testing tests and 73 app
  tests passed. `/tmp/bigscreen-history-final-tests.log`.
- New tests exercise durable reopen, unchanged diagnostics, stale/active rejection, retry
  visibility, keyboard dismissal/focus, empty-list navigation and menu-title identity.
- Rendered and inspected completed/failed menus at 1080p and the failed menu at 4K. Final captures:
  `.build/download-history-ui-final/` and `.build/download-history-ui-final-4k/`.
- In the signed production app, used the keyboard to dismiss A Short Hike's completed repair
  `BF512743-DCDE-4700-91E7-44CD34C7C27D`. Its row disappeared, focus moved to Oniken, and Aggelos
  remained visible. After a normal app restart, the same two entries remained and the A Short
  Hike entry stayed dismissed.
- Read-only catalog comparison showed all 9 jobs and all 3 installations unchanged. Exactly one
  presentation receipt was added for the completed repair. Private before/after inventories and
  owned-window captures are in `.build/download-history-live/`.

The completed A Short Hike entry is intentionally left dismissed. No game was launched and no
game files, originals or saves were changed for this validation. Physical controller acceptance
and the broader v1 release audit remain open.
