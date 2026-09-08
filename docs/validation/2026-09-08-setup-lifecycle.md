# First-run and Runtime lifecycle — 8 September 2026

Review of PRD 02 found two implementation gaps:

- The startup runtime inspection was untracked and could publish after a later preparation.
  Cancelled preparation also accepted a late successful reply and queued progress callbacks.
- Games-volume loading remembered a selected drive ID but left focus on row zero. Confirm uses
  the focused row, so reopening the picker did not initially select the saved drive.

All setup work now has a tracked task and generation. A new operation cancels and joins its
predecessor before invoking the next external service. Results and progress must still belong to
the current operation. Closing setup invalidates that generation; a cancelled preparation reports
stopped even when its service ignores cancellation and returns success. The tracked startup check
also participates in the existing reset/shutdown cancellation path. No changes to CrossOver's
template contents, game bottles or saves are involved.

Volume selection focuses the saved mounted drive first, then the recommended drive, then the first
available choice. The selected ID and controller focus agree, and confirmation persists that row.

Validation:

- `./scripts/test.sh`: 217 package XCTest tests (4 existing integration skips), 5 Swift Testing
  tests and 87 app tests passed. `/tmp/bigscreen-setup-lifecycle-tests.log`.
- Four new app tests use delayed runtime replies that deliberately ignore cancellation: startup
  inspection versus preparation, stopped preparation followed by retry with an old progress
  callback, closing/reopening Runtime during inspection, and saved/recommended volume focus with
  real confirmation and catalog persistence.
- Existing first-run retry/completion, Runtime settings navigation, Settings reset and session
  interaction tests still pass. Signed build: `/tmp/bigscreen-setup-lifecycle-build.log`.

This verifies task/input behavior with injected services and disposable catalogs. It does not
replace the remaining fresh-profile DS4 pairing/QR/TV acceptance, the two-minute setup measurement,
or a live external-drive disconnect/reconnect test. No live user setup was reset for validation.
