# Interrupted local save publication recovery — 8 September 2026

Continues the missing-bottle work in `2026-09-08-cloud-root-recovery.md`, covering FR-LAUNCH-1 and
FR-CLOUD-3/4/5/6. A reproduced failure left an empty replacement root permanently blocked when
the old Cloud operation had already begun replacing local files.

## Resulting behavior

- Recovery reconstructs the complete previously approved result from the immutable local and
  downloaded copies. This includes files selected for upload, download, preservation and deletion.
  It requires no network access. An empty replacement root can receive that complete result.
- Existing files matching the reviewed before/after fingerprints recover automatically within the
  original root. Different current progress prompts a controller-accessible review: **Keep current
  files** or **Restore recovered files**. Each choice selects a complete copy, including omissions.
- Current files and the complete recovery candidate are staged before the journal records a
  choice. Every review and accepted plan stays in history. Repeated interruptions use the last
  accepted result; later root replacement cannot silently revert to an earlier choice.
- Changed fingerprints or physical root identities invalidate displayed consent. The ordinary
  no-follow, ownership, stopped-writer and file precondition checks still protect publication.
- Local recovery does not contact Steam, attach a different account, or advance a Cloud baseline.
  Once the local result is verified, the coordinator retains the old operation and reconciles a
  fresh attempt with the current Steam account. Local recovery consent is not reused for that step.
- Play can take a preparation-only reservation for a released, pending local recovery. This permits
  runtime recreation and reapplication of the recorded recipe while retaining installation and
  ownership IDs. It rejects active workers, other sessions and changed save mappings. Only launch
  and staging metadata may be updated. A durable Cloud check runs before invoking the game runtime;
  offline launch stays blocked until local publication is complete.

## Evidence

`testInterruptedPublicationRecoversIntoReplacementRootWhileOffline` uses a persistent Catalog,
real SaveStore/filesystem, and a test transport. It interrupts a two-file publication after the
first file, moves the original aside, creates an empty replacement, reopens the catalog and puts
the transport offline. Before this change, the files remained absent and launch remained blocked:
`/tmp/bigscreen-cloud-publication-regression.log`. It now restores both files, preserves the moved
original's partial state, makes no remote write, and allows an offline session reservation.

Additional tests cover mixed upload/download/deletion results, both complete-copy choices,
stale consent, account switching after local recovery, another replacement after an accepted
choice, durable review receipts and stale-worker rejection, baseline restrictions, preparation
identity constraints, recipe reapplication before recovery, and launch/offline exclusion until
recovery completes. UI tests exercise directional selection and verify that recovery consent does
not include Steam account attachment.

Final suite: 214 package XCTest tests (4 existing integration skips), 5 Swift Testing tests and
77 app tests passed. Signed build passed. Logs: `/tmp/bigscreen-cloud-publication-final-tests.log`
and `/tmp/bigscreen-cloud-publication-build.log`.

## UI and remaining live acceptance

The recovery dialog follows the existing two-card Cloud design, with dates, file counts/sizes,
orange focus, explicit copy actions and controller legends. Its recovered-copy wording distinguishes
the locally staged recovery result from the live Steam Cloud copy. Keeping current files uses a
checkmark rather than an upload arrow.

The Mac is locked. The new explicit `--snapshot-offscreen` option uses SwiftUI ImageRenderer for
layout inspection without capturing the desktop. Recovery layouts were inspected at 1920×1080
and 3840×2160 under `.build/cloud-recovery-ui/` and `.build/cloud-recovery-ui-4k/`. These prove the
SwiftUI layout, not live window interaction or rendering of native NSViewRepresentable content.
The normal screenshot mode remains available for those checks.

Live CrossOver missing-bottle recreation, Cloud restoration and resumed A Short Hike gameplay
remain pending until the desktop is accessible. The user's live bottle has not been moved or
modified for this checkpoint. Settings reset and the other open v1 gates remain outstanding.
Final read-only checks confirmed its save hash and bottle inode still match the pre-test records,
with no unfinished live session or Cloud operation.

A separate case still needs an audit: root loss while only an upload is pending, before local
publication begins (or after local recovery completes but before the next Cloud attempt commits).
The staged local bytes remain retained, but this checkpoint does not prove that the UI will offer
that unsynced copy after another root loss. Do not treat the interrupted-publication tests as proof
of that different state boundary.
