# Library navigation CPU and lazy Home tiles — 8 September 2026

`LibraryModel.filteredGames` previously filtered and sorted the entire catalog on every read,
including multiple reads during one focus move. Home rebuilt its derived rows on every read and
constructed every tile in every row, even far outside the viewport.

Derived library and Home lists are now cached. Changes to games or collections invalidate both;
scope, query, sort and refinements invalidate the library list. Observable revision properties
ensure that warm reads still subscribe to input changes without mutating observed state during
view rendering. The caches are private transient state, independent of the persisted catalog.

Home constructs only rows near the vertical viewport and columns near each row's horizontal
viewport, retaining overscan for focus animations. Its existing coordinates, spacing, focus-driven
scrolling and final Continue Playing → Library card are preserved. Favorites and pinned collections
remain fully navigable. Missing covers now use a dark color derived from source/game identity,
with the existing title placeholder, as required by FR-ART-1.

## Validation

- Added a repeatable CPU benchmark with 720 games and 120 forward/back paging actions. Each
  action also reads the focused game, visible grid range, sorted list and Home rows. The same
  Debug test on the Apple M5 Pro measured:

  | Measurement | Before | After (targeted suite) |
  | --- | ---: | ---: |
  | Mean CPU per action | 5.243 ms | 0.013 ms |
  | p95 CPU per action | 5.494 ms | 0.003 ms |
  | Maximum | 5.712 ms | 1.218 ms |

  The benchmark includes the first Home list derivation as well as warm reads. These are model CPU timings,
  **not rendered frame times or proof of 60 fps**. Logs:
  `/tmp/bigscreen-library-performance-before.log` and
  `/tmp/bigscreen-library-performance-after.log`.
- All 98 app tests passed. Regression coverage verifies warm Observation subscriptions, title,
  install state, playtime, genre, query, sort, collection membership/name and hidden-state changes;
  reaching all 720 Favorites entries and returning to the first; reaching the last of 12 pinned
  collections; bounded construction (at most five nearby rows and 13 columns per row); empty
  catalog recovery; and the final Library card. Existing editing, filtering, persistence, Cloud,
  download, setup and session interaction tests also pass.
  `/tmp/bigscreen-library-performance-all-app-tests.log`.
- Signed build passed. `/tmp/bigscreen-library-performance-build.log`.
- Large-library snapshot fixtures use 720 synthetic identities with preview artwork and intentional
  missing covers. They neither load nor modify the user's catalog.
- Each snapshot now starts with a fresh model. Visual review exposed the previous screen-order
  dependency: rendering the Library card before Home left that card selected in the Home fixture.
  The library-return fixture now explicitly pages down before returning, so it exercises that path
  even when captured alone.
- Six screens rendered at 1920×1080 and four at 3840×2160 with reduced motion. Inspected normal
  Home, the final Library card, the final tile in the eighth 720-game collection, missing-art
  placeholders and the end of the 720-game library grid. Focused tiles/labels remain inside the
  safe area. `.build/library-navigation-1080/` and `.build/library-navigation-4k/`; render logs are
  `/tmp/bigscreen-library-performance-render.log` and `/tmp/bigscreen-library-performance-render-4k.log`.
- With zero unfinished sessions and zero Cloud claims, staged/launched the signed app from its
  stable Application Support bundle with normal quit handling. `/tmp/bigscreen-library-performance-run.log`.

PRD reconciliation follows already adopted decisions: board 3b uses full-color covers plus a
download glyph; the implementation plan returns game exits to Home and classifies short clean
sessions as clean. The stale library/exit paragraphs now agree with those decisions.

The live cold/warm 600+ title 60 fps gate remains open. Desktop lock prevents a representative
physical DS4/TV and compositor timing pass; offscreen captures cannot verify those requirements.
