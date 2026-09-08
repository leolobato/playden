# Steam acquisition sorting — 8 September 2026

The user reported that Recently added did not follow their Steam purchase order. The cause was
`Game.addedAt` being populated from `SourceGameRecord.firstObservedAt`: almost the entire initial
library had the import time, with no Steam ownership date.

SteamCore now maps each account-owned active license's creation timestamp through its PICS
package app IDs. The earliest applicable timestamp wins when multiple packages include a game,
so buying a later bundle does not make an already-owned game newly acquired. Foreign, inactive,
expired, unknown-date and future-date licenses do not contribute dates. This is the Steam
acquisition/activation date, not a billing receipt or amount. The license timestamp's acquisition
meaning is also documented by the [SteamUser client implementation](https://github.com/DoctorMcKay/node-steam-user#ownershipfilter).

Big Screen fetches license dates alongside its owned-library request and keeps ownership itself
defined by the owned-library response. Optional license metadata failure does not discard the
library. `sourceAcquiredAt` is a separate optional field; known dates survive temporary missing
metadata, while old catalogs decode with unknown dates until refresh backfills them. Public
metadata enrichment does not overwrite acquisition dates. Signing out clears the source cache,
preventing a new account from inheriting the old account's cached acquisition dates.

Recently added sorts by acquisition, descending, with unknown dates last and the existing name/ID
tie-breaker. First-observed timestamps remain available for their original bookkeeping purpose.

Dependency: sibling GameNative-macos `investigation/ios-runtime` commit `608a619`, used through
the existing local Swift package path. Existing sibling documentation/iOS work was preserved.

Validation:

- Sibling suite: 72 tests, 2 existing skips, no failures.
  `/tmp/bigscreen-acquisition-steamcore-tests.log`.
- Big Screen: 243 package XCTest tests, 6 existing integration skips, 5 Swift Testing tests;
  109 app tests, no failures. `/tmp/bigscreen-acquisition-all-tests.log`.
- Regressions cover earliest applicable package acquisition, duplicate/bundled licenses, invalid
  license exclusion, source mapping independent of discovery/playtime, old JSON decoding, cache
  backfill/reopen, missing metadata, account separation, and actual model sorting after refresh.
- Signed build/staging passed: `/tmp/bigscreen-acquisition-build.log`,
  `/tmp/bigscreen-acquisition-run.log`.
- Live profile started with 538 games and zero acquisition dates. The rebuilt app's normal startup
  refresh populated all 538 dates. Counts and expected ordering are recorded privately in
  `.build/acquisition-live/before.json`, `after.json`, and `expected-order.json`.
- Selected Recently added through the real filter sheet's accessibility button; confirmed the
  saved sort is `recentlyAdded` and visually inspected the owned-window capture
  `.build/acquisition-live/library-recently-added.png`. The first row matches the source dates:
  Slay the Spire 2, Look Outside, Mina the Hollower, Heretic + Hexen, Earthion, Pocky & Rocky Reshrined.
  UI command log: `/tmp/bigscreen-acquisition-ui.log`.

No game was installed/launched and no saves were changed. Live offline/account-switch acceptance
is still a separate v1 gate; the cache/account cases here are regression-test evidence.
