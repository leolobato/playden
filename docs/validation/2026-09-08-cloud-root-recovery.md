# Cloud baseline after runtime recreation — 8 September 2026

The missing-bottle recovery requirement in M4 exposed a verified deletion bug. The runtime can
recreate a missing bottle while keeping the installation ID, ownership token and path. Previously,
Cloud sync treated missing saves in that replacement as local deletions against the old baseline.

## Reproduction and fix

`testRecreatedBottleRestoresCloudWithSameInstallationAfterRestart` uses the real Catalog journal,
SaveStore and filesystem with a test Cloud transport. It first pulls a save, moves the original
bottle aside, creates an empty replacement at the same path, reopens the persistent catalog, then
syncs the same installation. Before the fix, sync reported success, deleted the server's save and
left the replacement empty. The failing run is `/tmp/bigscreen-cloud-root-regression.log`.

Local snapshots and successful baselines now record each mapped root's device, inode and creation
time, captured with `fstat` from the already opened directories. The planner only uses three-way
history for a root whose physical identity still matches. This requires no journal update between
bottle recreation and a crash: the next sync detects replacement from the filesystem itself.
Creation time also distinguishes reused inode numbers. Unaffected roots keep their own history.

Legacy baselines decode without this optional field. They cannot authorize deletion inference;
equal copies establish a new baseline, missing local files pull from Cloud, and differing copies
require review. Installation IDs, account attachment and remote revision checks remain intact.

The coordinator also checks identities when accepting conflict consent, before remote writes,
before local publication, and before recording completion. Immutable backups remain available.
An already interrupted local publication still needs recovery against its original root/content
preconditions; replacing that root does not grant permission to apply an old review elsewhere.

## Validation

- Regression now restores the original bytes after restart with zero remote writes and the same
  installation ID. The moved original remains unchanged.
- Tests cover genuine save edits/deletions, legacy baselines, inode reuse, independent roots,
  replacing an empty root just before a remote deletion, rejecting stale conflict consent even
  when replacement files have identical bytes, and rejecting publication into a replacement root.
- Full suite: 205 package XCTest tests (4 existing integration skips), 5 Swift Testing tests and
  76 app tests passed. `/tmp/bigscreen-cloud-root-all-tests.log`.
- Signed build passed. `/tmp/bigscreen-cloud-root-build.log`.

## Live acceptance remains open

The signed app was rebuilt and staged. Read-only checks found no unfinished session, job or Cloud
operation. A Short Hike's current 29,453-byte save matches its revision-3 Cloud baseline fingerprint.
The catalog and save were backed up privately in `.build/cloud-root-live/`. Its actual current
save hash is recorded there; do not substitute hashes from earlier gameplay checkpoints.

The Mac became locked before live interaction. Accessibility and screen-capture preflight checks
returned true, but `CGSSessionScreenIsLocked` was true and owned-window capture failed. Old files
left at screenshot paths are not new evidence. No bottle was moved, removed or recreated, and no
live game was launched for this checkpoint.

Still required: run the real missing-bottle preparation/recipe/Cloud restoration path with A Short
Hike once the desktop is available, and verify gameplay resumes. Also exercise replacement during
an already interrupted local publication; the current identity guard retains both copies and
blocks that old publication, but a user-facing recovery flow for a permanently lost original root
is not yet verified. These are open M4 acceptance items, not passing claims.
