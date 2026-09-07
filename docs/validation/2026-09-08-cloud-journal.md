# Durable Cloud journal — 8 September 2026

Catalog migration v3 adds Cloud attempts, account-scoped baselines and installation-scoped account
attachments. Attempt records preserve the reviewed remote list and plan, immutable local/remote
snapshot references, upload batch receipts, failures and a versioned worker claim. Staged context
cannot be replaced; superseded attempts keep their receipts and backup references as history.
Completion commits the verified baseline, account attachment and terminal attempt atomically.
The database rejects baselines with the wrong identity, older known revisions or fingerprints
that differ from the staged result. Logout leaves this state intact.

The claim shares the session/maintenance transaction boundary. Cloud cannot acquire it during a
running session or unfinished install/repair job. New play sessions and maintenance cannot acquire
the game while Cloud holds it. A pre-launch sync may use its caller's preparing session only while
that session has no runtime receipt. Account changes require explicit attachment before uploads
or replacement of existing local progress. Terminal job history can still be reordered while
Cloud runs; it does not claim or write game files.

Claims do not expire on a timer and reopening the database does not reset them. Explicit recovery
requires the coordinator to establish that the old worker has stopped, and version/claim checks
reject stale callbacks. Interrupted remote transfers retain their batch receipts and baseline.
Pending network work can release its claim for offline play. Once local replacement starts, a
durable recovery flag blocks play/maintenance even after failure, until a complete result has been
verified. Removing installation bookkeeping rejects unfinished Cloud attempts, including paused
ones; the future uninstall flow must resolve or explicitly discard them before removing files.

Validation:
- Nine Cloud journal tests cover reopening the database, receipts, stale callbacks, concurrent
  launch/sync claims (20 races), maintenance exclusion, pre-launch runtime transitions, explicit
  account attachment, logout/reinstall identity, atomic baseline rejection/completion, immutable
  conflict backups, pending/offline behavior and partial local application recovery.
- Full suite passed: 125 package XCTest tests (3 existing integration skips), 5 Swift Testing
  tests and 55 app tests. Log: `/tmp/bigscreen-cloud-journal-all-tests.log`.
- A subsequent queue-history fix allows completed/cancelled records to be reordered while Cloud
  holds the game. All 19 Catalog/journal tests passed after that change:
  `/tmp/bigscreen-cloud-journal-final-tests.log`.

These tests exercise the real SQLite journal with temporary databases and simulated staged-copy
IDs. They do not prove filesystem replacement, process ownership recovery or live Cloud writes.
The coordinator still must verify owned roots, publish and hash actual staging copies, reconcile
interrupted remote batches, validate both final sides, and connect launch/exit, offline choices
and the controller conflict screen. No live saves were changed and Cloud sync is not enabled in
the app yet. Local uninstall retention remains deferred.
