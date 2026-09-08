# Preparation progress and installation quit confirmation — 8 September 2026

The user reported Armored Core VI remaining on “Preparing game” with a full
64.97 GB download bar and no confirmation when quitting Big Screen.

## Live findings

Read-only inspection of the installed app and catalog found the job running its
preparation stage. SteamInstaller checks the original files again before making
changes, including recovery checks for saved originals. This second check had no
UI progress callback. The completed download counter therefore obscured ongoing
disk work.

A three-second process sample showed FileHandle reads and SHA-1 verification in
SteamInstaller.prepare. Repeated open-file observations showed the read offset
in Game/Data0.bdt advance approximately 1 GB. It was making progress at the time
of inspection; this does not establish that every later setup step completed.
Previous pauses/restarts can repeat an unfinished check of the 64.97 GB install.

At the latest read-only check, around 23:14 local time, the installed app was
closed and the job was queued at preparation with 64,970,880,671 downloaded bytes
preserved. This investigation did not quit, replace, or relaunch the installed app.

## Changes

- Preparation emits ordered progress events for verification, executable
  preparation, and applying game settings. Original-file checks remain intact.
- Downloads shows actual checked bytes, percentage and current file during the
  preparation check. Subsequent setup steps have descriptive activity labels.
- The queue rejects stale or out-of-order events and clears verification when
  setup advances, instead of retaining the completed download bar.
- Quit from the UI, window close and application termination requires
  confirmation during queued/running/stopping installation work as well as games.
  The installation-only warning explains that downloaded files are preserved and
  file checks may restart. Cancellation leaves the queue alone; confirmation uses
  the existing checkpoint/shutdown path.

## Validation

- Targeted package suites: 38 tests, 1 skipped, 0 failures, including real fixture
  preparation events and queue ordering/stage transitions.
- App suite: 153 tests passed and one render/OCR assertion failed because OCR
  read a filename's zero as the letter O. The assertion was made tolerant of that
  OCR ambiguity; its focused rerun passed. All 154 test cases have passing results.
- Rendered 1080p Downloads and installation-only quit overlay were visually
  inspected. They show 50%, checked bytes, the current file, and the correct quit
  consequences with Keep launcher open selected by default.
- Release build passed, and the resulting app passed deep/strict code-signature
  verification. Build log: `/tmp/bigscreen-preparation-release.log`.
- Logs: `/tmp/bigscreen-preparation-package-tests-final.log`,
  `/tmp/bigscreen-preparation-app-tests-final.log`, and
  `/tmp/bigscreen-preparation-render-final.log`.

The updated UI and quit flow still need acceptance in the installed app. The
controller disconnect/system input freeze is a separate, unconfirmed investigation
tracked at the top of NEXT_SESSION_HANDOFF.md.
