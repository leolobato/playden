# Diagnostic journal, text archive and TV viewer — 8 September 2026

Job and session checkpoints now record bounded, redacted diagnostic histories in the same database
transaction as the operation. Ordinary progress checkpoints do not duplicate stage events; retries
remain visible. Rotation retains the ten most recently updated operation logs per game across jobs
and sessions, without deleting operational records, diagnostics referenced by those records, or
playtime. Migration imports existing snapshots with an explicit notice that earlier stage history
was not captured.

The app mirrors retained diagnostics to `~/Library/Application Support/Big Screen/logs/<source>-<id>/`
as `operation-<UUID>.log`. Output is capped at 256 KiB and timelines at 512 events with omission
notices. Redaction precedes truncation, and UTF-8 boundaries are preserved. The archive uses private
atomic file replacements and directory-relative, no-follow access; it rejects linked target files
and folders. Rotation leaves unrelated files and links untouched. Missing files are reconstructed
from the journal. A failed mirror does not cancel a game or installation; the viewer exposes the
error and the next synchronization retries it. Normal application shutdown attempts a final flush.

The TV viewer now uses a native wrapping text viewport with mouse selection and scrolling. Up/down
scrolls, page controls move a larger distance, and left/right selects Close or Reveal in Finder.
Back closes the modal; other navigation stays trapped. The footer shows scroll instructions and
position. About now displays app/runtime/template versions and an Open logs folder action.

## Validation

- Full regression suite: 192 package XCTest tests (4 integration skips), 5 Swift Testing tests,
  and 76 app tests passed. `/tmp/bigscreen-diagnostics-final-tests.log`.
- Six new package tests cover stage/retry persistence, transaction rollback, mixed job/session
  rotation, migration honesty, redaction and Unicode bounds, missing-file restoration, file
  permissions, path identity and symlink containment. Three app tests cover modal input, unavailable
  actions and native wrapping/scroll bounds.
- Final signed build passed: `/tmp/bigscreen-diagnostics-final-build.log`. The only changes after
  the full suite add snapshot-driver cases for exercising both scroll limits.
- Inspected empty/long log layouts at 1080p and the long layout at 4K. Captures are in
  `.build/diagnostics-ui/` and `.build/diagnostics-ui-4k/`. The real input path paged a 100-line fixture
  to its final line and back to the top; inspected captures are in `.build/diagnostics-ui-final/`.
- Live migration created 16 retained text files across three games. Read-only before/after
  comparisons confirmed all jobs, installations and sessions were unchanged by migration.
- A fresh A Short Hike Verify files job, `5B9ACF59-B2A2-4A4E-9871-00B8D5263B89`, completed and
  recorded eight stage transitions through `finished · completed`. Its text file appeared and the
  live viewer displayed the complete timeline. All 240 game-file hashes and the save hash remained
  unchanged. Private database backup, inventories and owned-window captures are under
  `.build/diagnostics-live/`.

## Remaining diagnostics work

The journal currently captures persisted failures and session runtime output. Successful finite
setup-command stdout/stderr and the pre-launch Cloud-phase timeline still need explicit collection;
FR-LOG-1 is not fully closed by this checkpoint. Reset app data also remains outstanding.

Reveal in Finder is wired to the materialized log and was activated from the live viewer, but
Finder scripting reported no selected item or matching folder window. A direct `open -R` probe
gave the same observation. This does not prove the desk-debugging flow worked; keep live Finder
acceptance open. Physical DS4/TV acceptance and the broader release matrix remain open as well.
