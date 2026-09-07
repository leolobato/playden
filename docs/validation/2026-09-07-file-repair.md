# Installed-file verification and repair — 7 September 2026

Verify files on an installed game creates a durable repair job using its original pinned plan,
manifest, installation location and ownership token. The serial queue checks originals, repairs
missing/damaged content, reapplies preparation, validates the result and commits the existing
installation identity/date. It does not resolve the latest game version.

Steam repairs modified API originals at their recorded `.orig` paths, keeping staged DLLs in
place until preparation runs again. Unrelated game files and saves are retained. A failed or
cancelled repair leaves the installation marked as requiring verification. Play remains blocked
until a later verification succeeds. Repair/session claims are serialized in Catalog transactions,
so a running game cannot acquire a repair job or race a new session into maintenance.

Downloads shows Checking and repairing files, Files verified, Verification failed or Verification
stopped. It offers pause/resume, retry and Stop verifying. The stop confirmation explicitly says
that files/saves stay in place and verification must finish before playing again.

## Evidence

- Source test: missing executable and short original API backup restored from fixture chunks;
  staged API untouched during download, damaged staging regenerated, unrelated save retained.
- Queue tests: failure/restart/retry uses the pinned plan and completed download; installation ID,
  date and owner preserved; cancellation keeps game directory/bottle and the play guard; a new
  verification clears that guard; active session prevents repair.
- UI test: repair primary action, labels and non-destructive stop explanation.
- Full suite: 138 passed, 3 existing skips. Log: `/tmp/bigscreen-repair-final-tests.log`.
- Live A Short Hike check: backed up its owned 49-byte `AShortHike_Data/boot.config`, shortened
  the test file to 5 bytes while no game was active, and invoked Verify files from the game page.
  The real Steam repair completed; restored bytes matched the backup exactly. Installation ID,
  owner and installed date were unchanged; `needsRepair` cleared only after validation.
- The native completed Downloads view showed A Short Hike / Files verified. Capture:
  `.build/setup-ui/ashorthike-live.png`; backup/evidence: `.build/repair-live/`.

This establishes installed-file repair. Uninstall/save retention and the newly required v1
Steam Cloud synchronization are separate unfinished features.
