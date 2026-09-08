# Settings reset — 8 September 2026

Settings → About → Reset app data opens a review of what resets and what stays. Cancel receives
initial focus. Keyboard/controller input stays inside the dialog, and busy reset cannot be
dismissed or bypassed to launch a game. Application termination waits for reset to finish.

Confirmed reset signs out the source, clears cached owned games/source refresh timestamps,
favorites/hidden flags, collections, compatibility ratings/notes, library/display/setup preferences
and download-history dismissals, then returns to controller setup. It preserves installation
ownership and recipes, all jobs/progress, play sessions/history, the Cloud client ID, account
attachments/baselines, recovery operations/archives and diagnostic records. It performs no game,
bottle, original DLL or save-file deletion. Paused downloads remain paused.

An unfinished session, active Cloud claim, pending removal, stopping job or job that is neither
failed nor explicitly user-paused prevents reset. The final database transaction rechecks these
conditions. Authentication, periodic polling, library refresh, setup and install-offer tasks are
cancelled and joined before sign-out, including a refresh that ignores cancellation. New input
cannot start authentication, refresh or play while reset is busy.

Keychain and SQLite cannot commit together. Sign-out failure leaves personalization untouched.
Database failure rolls back all local deletions and reports that the account is signed out;
retry is explicit. A crash between those operations may leave a signed-out profile with its old
settings, without claiming reset completed.

Validation:

- `./scripts/test.sh`: 217 package XCTest tests (4 existing integration skips), 5 Swift Testing
  tests and 83 app tests passed. `/tmp/bigscreen-reset-final-tests.log`.
- New tests compare preserved operation payloads and save/original-file bytes after reopening
  the database, verify Cloud identity and recovery preservation, inject a mid-transaction SQLite
  failure, exercise active-operation blockers, navigate the dialog, retry sign-out/database
  failures and join a late owned-library response before reset.
- Signed build passed: `/tmp/bigscreen-reset-build.log`.
- Offscreen snapshot fixtures cover About, confirmation, blocked, failed and busy reset at
  1920×1080 and 3840×2160 in `.build/reset-ui/` and `.build/reset-ui-4k/`.

Reset was tested against disposable catalogs and fake authentication. The user's actual Steam
profile was not reset or signed out for this test. Offscreen rendering is layout evidence;
physical controller and live window acceptance remain outstanding while the desktop is locked.
