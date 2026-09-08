# Pending upload archives after runtime loss — 8 September 2026

## Problem and resulting behavior

A failed Cloud attempt already holds an immutable local save archive. Previously, retry retired
that attempt before taking a new snapshot. If the runtime had been lost and recreated, the fresh
snapshot could be empty and the pending progress would remain only in retired history. This also
left a crash interval between retiring an attempt and recording its replacement.

Retry now checks the archived snapshot's physical save-root identities before retiring it. When
the root changed, it prepares local recovery from that attempt's verified archive, even if Steam
was unreachable before a Cloud plan could be made. Empty replacement roots can recover the saved
files automatically. Different current progress requires an explicit choice between complete
copies, with both archived first. Archives without root identities require review when their
contents differ. Ordinary offline edits within the same root remain the latest local state.

This local recovery has a separate journaled input. It preserves the original Steam plan, account,
batch receipts and archive references. It cannot authorize a Steam upload, account attachment or
baseline commit. After local recovery, Big Screen performs a fresh Steam check and applies the
existing account/conflict rules. Offline play remains unavailable while a local recovery choice or
publication is unfinished.

The replacement attempt and its verified local snapshot reference are now recorded in the same
SQLite transaction that retires the prior attempt. A further root change before that checkpoint
keeps the original attempt pending for recovery. A completed local recovery is also recoverable
after another root replacement using its last accepted complete copy.

## Validation

- Full regression suite passed: 240 package XCTest tests (6 opt-in integration skips), 5 Swift
  Testing tests and 88 app tests; no failures. `/tmp/bigscreen-pending-archive-all-tests.log`.
- Service tests use the real Catalog journal, SaveStore, physical directories and immutable archives
  with a deterministic Cloud transport. They cover an offline pending upload without any Steam plan,
  Catalog/service restart, two successive root replacements, preservation of archive references,
  current/recovered whole-copy choices and separate account confirmation after connectivity returns.
- Boundary injection replaces the root immediately before the fresh snapshot, both on an ordinary
  retry and after local recovery. Offline play stays blocked, the original attempt remains pending,
  and a subsequent retry restores the archived progress.
- Lost upload-response coverage now removes/recreates the save root after the server has committed.
  Recovery restores local progress, reconciles the remote result and does not upload a second time.
- Journal tests reject a foreign archive reference, replacement during unfinished local recovery,
  remote-write/account transitions from the local-only recovery and stale callbacks. Reopening
  Catalog finds one active replacement with its fresh snapshot and the preserved prior archive.
- Controller interaction coverage verifies recovery choices and exact consent when the original
  operation has no Steam plan or remote list. Account attachment remains false for either local
  recovery choice. `/tmp/bigscreen-pending-archive-ui-tests.log`.
- Signed build passed and the updated app was staged/launched normally after confirming no
  unfinished session or active Cloud claim. `/tmp/bigscreen-pending-archive-build.log` and
  `/tmp/bigscreen-pending-archive-run.log`.

No live game installation, save or Steam Cloud file was modified by these tests. Physical
missing-bottle → Cloud restore → gameplay/controller acceptance remains open while the desktop is
locked; these filesystem and journal checks do not claim that live end-to-end result.
