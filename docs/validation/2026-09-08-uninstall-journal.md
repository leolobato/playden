# Durable uninstall authorization — 8 September 2026

Added the Catalog/Domain boundary for v1 removal without local save retention. An uninstall review
captures the exact installation, latest session and Cloud operation history. Beginning removal
compares that review again in the same transaction that reserves the uninstall job. New play, a new
sync attempt or changed installation invalidates stale confirmation.

A fresh successful Cloud check after the latest session permits removal without an additional
discard decision. Missing, unsupported, conflicting or pending sync requires explicit consent to
discard unsynced local progress. An active Cloud claim or incomplete local-file recovery blocks
removal even with that consent. Discard retires pending attempts with a durable explanation and
retains their backup references; it does not advance a baseline or delete remote files.

The reservation blocks play, new maintenance, Cloud access and generic installation changes.
Generic queue writes can reorder an existing uninstall but cannot forge its authorization or
cancel/complete it. Version-by-value checkpoints reject stale workers, preserve removal ordering
and retain the reservation on failure/restart. Completing the job removes install state and marks
the job finished atomically, retaining edits, collections, sessions and Cloud history. The worker
must verify owned filesystem removal before reporting those checkpoints; the Catalog cannot prove
physical deletion by itself.

Validation:

- Six new tests cover explicit discard, active-sync/local-recovery blocking, stale review after
  play/sync/install changes, old green status after offline play, mutation/consent bypass prevention,
  and restart/completion/metadata preservation with a real temporary SQLite database.
- Catalog tests: 28 passed. `/tmp/bigscreen-uninstall-journal-tests.log`.
- Full `./scripts/test.sh`: 169 package XCTest tests (4 skips), 5 Swift Testing tests and 61 app
  tests passed, no failures. `/tmp/bigscreen-uninstall-journal-all-tests.log`.

This boundary is not yet connected to the install queue worker or app confirmation. The existing
live Uninstall placeholder remains until owned file/bottle deletion, interruption handling and the
controller flow are implemented together. No live uninstall job was created and no installation
was deleted during this checkpoint. Next: worker integration, runtime-writer/ownership checks,
confirmation and retry UI, then A Short Hike uninstall/reinstall with Cloud restoration.
