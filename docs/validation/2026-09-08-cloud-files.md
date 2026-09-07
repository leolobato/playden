# Cloud save staging and local application — 8 September 2026

SaveStore can publish a complete downloaded Cloud set with its account, revision and file list.
Payload hashes, mapping coverage and duplicate destinations are checked before publication.
Staging is immutable and verified on reopen; individual bytes can be read for an upload or conflict
choice without reading a game's live file. Limits are 64 MiB per remote file and 512 MiB per set.

Local application requires the coordinator to hold the Catalog claim, stop the game writer, verify
owned roots, obtain account/conflict consent and persist the local-recovery flag before calling.
It checks both staged sets against the reviewed plan and preflights every mapped live file before
the first mutation. Missing/unexpected files or a third fingerprint stop application. Atomic file
exchange keeps complete content at replacement targets; exclusive rename publishes missing files
without a transient hard-link state. Deletion moves the reviewed file into a stable temporary name
before removing that copy. Both immutable backups remain available afterwards.

Retries accept a mixture of reviewed original and intended final files. Stable temporary names
allow recovery before/after an exchange or deletion; unrecognized temporary content is retained.
Scratch filenames are reserved and excluded from wildcard save discovery. New directories and
published files are synchronized before completion. Final live files are scanned and hashed again.

CrossOverGameBottles now exposes an ownership-checked physical save root, without creating a bottle
or claiming its game has stopped. An initial test caught async protocol fallback dispatch selecting
the unavailable default; making the concrete method explicitly async fixed it.

Validation:
- Nine new filesystem tests cover empty-install restore, replacement/deletion, original filename
  case, timestamps, preserved backups, interruption between files, mixed-state recovery, unexpected
  live saves, unresolved conflicts, account mismatch, corrupt staging, invalid downloads, traversal,
  symlinks/hardlinks, primitive publication recovery and wildcard scratch exclusion.
- A bottle access test verifies missing/unowned roots are rejected and ready roots are physical.
- Full suite passed: 135 package XCTest tests (3 existing integration skips), 5 Swift Testing tests
  and 55 app tests. `/tmp/bigscreen-cloud-files-all-tests.log`.
- Afterwards added directory-creation synchronization, a final file recheck and coverage for a
  fully staged replacement interrupted before exchange. All 14 Cloud/local save-store tests passed:
  `/tmp/bigscreen-cloud-files-final-tests.log`.

Tests use temporary owned fixture folders and real macOS filesystem operations. They do not prove
power-loss durability on every external filesystem or full live Steam sync. The coordinator and
launch/exit/conflict UI remain outstanding. No live game saves or remote Cloud files were changed.
This implements sync staging/conflict backups; local uninstall retention remains deferred.
