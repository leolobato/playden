# Cloud coordinator checkpoint — 8 September 2026

`CloudSyncService` connects the existing reader, uploader, planner, journal and verified save
store. Local progress is copied and journaled before network access. Each retry records a fresh
copy, so progress made during offline play cannot be replaced by an earlier attempt's snapshot.
Downloaded copies remain bound to the reviewed account and revision. Upload batch receipts are
persisted before transfer, and the baseline advances only after local and remote verification.

Conflict/account consent refers to the exact displayed operation. Any change to its local hashes
or remote list forces a new review. Interrupted local application finishes from the retained
copies before offline play is permitted. Completed local recovery can release that restriction
while network reconciliation remains pending; it does not claim successful Cloud sync.

The transport client ID is generated once and stored separately from editable library preferences.
Root access and upload validation are mandatory injected dependencies. Validation also runs for
deletion-only remote writes, which must not bypass the checks required after a crash/forced exit.

## Validation

Nine coordinator tests use real temporary files, immutable snapshots and SQLite, with a simulated
Steam transport. They cover:

- Download, local edit, upload, baseline persistence and stable client identity after reopen.
- Explicit conflict resolution with both original copies retained.
- Network failure, further offline progress and retry using the newest local copy.
- A committed upload whose response is lost, reconciled without uploading twice.
- Rejection of conflict consent after either side changes.
- Account switch and failed upload validation without remote writes.
- Interrupted local application recovered offline before allowing a new session.
- Validation of deletion-only writes, followed by a successful checked retry.
- Rejection during an active session, while permitting its own pre-launch claim.

Full regression passed: 144 package XCTest tests (3 existing integration skips), 5 Swift Testing
tests and 55 app tests, with no failures. Output: `/tmp/bigscreen-cloud-service-all-tests.log`.

## Remaining integration

This coordinator is not yet enabled in the live app. Production callers must supply owned game
and bottle roots, establish that game writers have stopped, and validate save data appropriately
after an unclean exit. A Short Hike's actual save is binary; the textual test fixtures do not
validate that format. Session preparation/exit/startup recovery, offline and retry actions,
controller-accessible conflict/status UI and live Steam upload/reinstall restoration remain.
Post-exit work needs a durable handoff that cannot race a new launch or repair. No live Cloud
uploads or deletions were performed by this checkpoint.
