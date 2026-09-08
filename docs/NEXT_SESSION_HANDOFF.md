# Next session handoff — 8 September 2026

## Current priority — monitor, audio and quit controls

The user redirected this pass to the Wine monitor issue, then requested a preferred
output device, a visible Quit game action, and a visible Quit Big Screen action.
Generic focus-engine work is suspended in `stash@{0}` named
`WIP generic focus engine and Home Library integration before Wine monitor investigation`.
Do not pop it into these changes automatically. Existing user depot/download and
design edits remain separate and uncommitted.

The live A Short Hike window was successfully moved from LG to the preferred ASUS
without restarting it. Startup placement now waits for an eligible game window
before starting its ten-second movement budget. Audio is configured per game bottle
on launch, without changing the Mac's output. Both quit actions are now visible and
use the existing session/shutdown controls. See the [monitor investigation](validation/2026-09-08-wine-monitor-startup.md)
and [audio/quit validation](validation/2026-09-08-preferred-audio.md).
The updated installed helper still needs a real cold-launch acceptance check;
physical audio playback/reconnect and live quit remain acceptance items. The current
installed app has not been replaced during the active game session.

## Current resumption — 8 September 2026

The user has resumed implementation of this handoff and asked to check stale instructions.
The pause account below is historical. At the start of this pass, `main` was at `2cbd398` and
`/Applications/Big Screen.app` was running; the earlier claim that both apps are closed must not
be used as current state. Desktop availability has been requested; until answered, continue
implementation/automated checks without launching games, moving windows or sending input.

Changes since the paused checkpoint include self-contained release packaging/sign-in recovery,
remembered launch choices, download-size caching and transfer/resume verification progress.
Pre-existing uncommitted depot-boundary download fixes and design work were preserved.

This pass fixes the quit consequence being replaced by warnings, adds 1080p/4K long-warning
render/OCR coverage, and separates PS tap from hold so one press cannot emit both actions.
Automated test hosts no longer activate the launcher or terminate when a fixture window closes.
The user's subsequent verification-percentage request is implemented across Downloads/details/the
compact indicator, using actual aggregate checked bytes during original and final verification.
The current installed app was not replaced during its active installation.
See [implementation validation](validation/2026-09-08-handoff-implementation.md) and
[the 109-requirement inventory](validation/2026-09-08-v1-requirement-audit.md).
The inventory distinguishes partial evidence from missing implementation and physical acceptance;
it does not sign off v1. The full live quit cancel/confirm round trip remains open.

The launch-delay discrepancy is reconciled in the plan: the retained PRD/adopted design's
indefinite spinner and exit escape hatch apply; the proposed 60-second state was not adopted.
Fetch/decode/disk caching and cancellation now live in the separate Artwork package target; the
NSImage/memory presentation adapter stays in App. Generic focus-container/nearest-geometry
architecture remains a real implementation gap.
The private old UI helper now guards a missing process and has been typechecked; its historical
bundle/path selection must be revalidated before use with the current installed app.

## Historical pause requested by the user

The user needs the Mac now. **Do not resume interactive testing, launch games, open Big Screen,
move windows or send keyboard/controller events until the user resumes the work.** The v1 goal
is unfinished. This pause is not a release sign-off or an external blocker.

Big Screen and the A Short Hike test runtime are closed. Read-only cleanup checks found zero
unfinished sessions, zero job claims and zero owned/unreadable Wine processes for A Short Hike.
The test save checksum and byte count equal their pre-test values. No build, snapshot or game
command is intentionally left running. Do not relaunch the app merely to restore a test setup.

The user subsequently resumed **only the Oniken startup crash check**. That check passed after
they clarified the trigger as Play in Oniken's Windows launcher: Stage 1-1 rendered, the user
confirmed no crash, and the session ended cleanly. Both apps are closed again. Oniken's updated
gameplay save is retained with a pre-test backup; all other v1 work is still paused. See
[the updated interface validation](validation/2026-09-08-steam-interfaces.md).

## Checkout and preservation

- Big Screen is on `main`. Completed checkpoints: `b779c28` drive availability, `f0a76d7`
  informational notifications, `7655667` minimal-environment validation, `e2d6867` game focus.
- Quit confirmation was checkpointed in `7b95dfb` as work in progress; confirmed live shutdown
  acceptance remains open. The subsequent Oniken validation does not close that separate item.
- SteamCore now lives in `Packages/SteamKit`; Big Screen no longer depends on a sibling checkout.
- Preserve the user's uncommitted Big Screen design files:
  `docs/design/Big Screen.dc.html`, `docs/design/README.md`,
  `docs/design/screenshots/3b-library-download-glyph.png`, `3b-tile-detail.png`.
  They were not included in implementation commits.
- Preserve the sibling's modified handoff/runtime/docs files and untracked iOS plans/`poc/ios/`.
  The separate `GameNative-macos-steam-interfaces` worktree is also user-owned; leave it intact.
- No subagents. Continue incremental commits when the user resumes. Do not push/publish unless asked.

## Current implementation and evidence

The user-facing [README](../README.md) covers setup, features and v2/future scope.
[Development](DEVELOPMENT.md) records package layout, signing and build commands.
[Implementation plan](IMPLEMENTATION_PLAN.md) retains the complete milestone/acceptance scope.
Older progress notes are historical; an old unchecked milestone does not by itself prove that
all its code is still missing. A complete requirement-by-requirement audit remains outstanding.

Implemented areas include Steam sign-in/catalog, acquisition-date sorting, library editing,
Home navigation/cap/final Library card, design 3b download glyphs, bounded artwork caching,
keyboard/controller input, fullscreen and preferred display, runtime setup/recovery, persistent
download/repair/uninstall jobs, play sessions, diagnostics/retry, Steam Cloud and guarded reset.

Recent completed work:

- **Steam acquisition sort:** `b478589` plus sibling `608a619`. All 538 live library entries
  received acquisition dates; native Recently added ordering was inspected. Unknown dates go
  last; the import/discovery timestamp is no longer the sort source.
- **Cloud:** real A Short Hike upload/download, uninstall/reinstall restore, and missing-runtime
  recreation/save restoration have passed. See `validation/2026-09-08-live-runtime-cloud-recovery.md`
  and `2026-09-08-uninstall-live-restore.md`. This does not imply all titles have supported mappings.
- **Minimal environment:** staged app launched under `env -i` with only HOME, system PATH and
  LANG; fresh authenticated Cloud read, rendered UI, game launch/input/clean exit passed. Linked
  app/compression libraries have no Homebrew paths. See `2026-09-08-minimal-environment.md`.
- **Notifications:** real job/controller events, no historical replay, no focus capture, five
  visible seconds, modal/game deferral, persistent disconnection warning. Downloads retains
  Retry/View logs. Rendered timer test and 1080p/4K captures passed; `f0a76d7`.
- **Drive availability:** resolves each installation's own saved volume UUID/bookmark, refreshes
  on installation changes and AppKit volume/wake/activation events, rejects stale results,
  preserves Installed/recent rows and focus, disables Play with a reason. Includes real local
  filesystem/foreign-UUID and multi-volume fixture tests; `b779c28`. Physical eject/reconnect
  acceptance has not been performed. See `2026-09-08-installation-drives.md`.
- **README:** end-user setup, features, controller/keyboard controls, Cloud consequences and
  v2/future roadmap are written; `9736267`.
- **Oniken startup crash:** supplied SteamCore fix is integrated into sibling main (`9ce9f16`)
  and active history (`13312ff`); preparation regenerated all 17 interfaces. The user clarified
  and replayed the startup trigger on the later live run and confirmed it no longer crashes.
  Stage 1-1 and clean exit are recorded in `validation/2026-09-08-steam-interfaces.md`.

## Work in progress: quitting Big Screen while a game runs

Files: `App/LauncherQuit.swift`, `LibraryModel.swift`, `SessionModel.swift`, `SessionViews.swift`,
`BigScreenApp.swift`, `SessionSnapshots.swift`, and `Tests/AppTests/LauncherQuitTests.swift`.

Normal Quit now cancels the initial AppKit termination request and opens the existing elevated
game overlay with **Keep launcher open** (default) and **Quit game and launcher**. Closing the
main window also uses that path while a session is active. Confirmation is bound to the current
session, consumed once, and invalidated when the session changes. Cancellation keeps the game;
confirmation enters the existing queue/session/Cloud shutdown path. Input is trapped above
Cloud/controller panels, and cancellation remains possible during a pending session command.

Evidence on this code:

- All **137 app tests passed**: `/tmp/bigscreen-launcher-quit-tests.log`.
- Signed build passed: `/tmp/bigscreen-launcher-quit-build.log`; staged with
  `/tmp/bigscreen-launcher-quit-run.log` before the live test. The staged app is now closed.
- Four native snapshots (confirmation and quitting, 1080p and reduced-motion 4K) are in
  `.build/launcher-quit-1080/` and `.build/launcher-quit-4k/`. The 1080p confirmation was inspected.
- Live A Short Hike session **F2B9E84D-DD4B-4B5D-8B6B-38B602D9A7B8** showed the new confirmation
  after a normal launcher quit request. Its default Keep launcher open button was invoked.
  The turn was then interrupted; do not claim a fully verified cancel-and-confirm round trip.
- Cleanup requested normal app quit. The app exited before subsequent helper steps, which then
  failed because no launcher process existed. This was a helper force-unwrap failure, not evidence
  of an application crash. The final session record says `clean` (about 122 seconds), with no
  unfinished session/claims/runtime processes. The exact reason it ended before those helper
  steps was not investigated because the user needed the computer. **Do not count this as proof
  that the new affirmative confirmation path passed.**
- Private evidence: `.build/launcher-quit-live/confirmation-default.png`, `foreground-before.txt`,
  `session-running.json`, `session-at-pause.json`, `save-before.json`, `save-at-pause.json`.

### First fixes/checks after resuming

1. **Quit confirmation consequence — implementation fixed in the resumed pass.** In the historical live capture, an existing
   focus warning replaced the entire unsaved-progress/closing-app explanation because
   `GameExitOverlay` uses `sessionIssue?.reason ?? consequence`. Keep the consequence and show
   relevant errors separately; do not let an unrelated focus warning replace destructive-action
   consequences. The resumed pass separates/bounds diagnostic text and checks both layouts; live shutdown acceptance is still open.
2. **Recheck focus under controlled conditions.** Earlier `e2d6867` live tests passed automatic
   focus, Shift–Home and Return. The latest run had Terminal foreground and an inactive game,
   then showed the keyboard-focus warning again. This may involve foreground activity during
   testing; the cause is not established. Avoid helpers that activate Terminal or blindly claim
   the earlier fix proves every run. Confirm exact process/start/window identity and passive
   foreground state. Also verify Return after cancelling launcher quit.
3. Complete live normal Quit → cancel (same running session remains) → normal Quit → explicit
   Quit game and launcher (both close, jobs checkpoint, Cloud/pending journals settle). Include
   window close, keyboard and DS4 paths, and a failure/retry case where practical. Do not launch
   a game while the user is using the Mac. Use A Short Hike, not Oniken, for general UI testing.
4. The private helper `/tmp/bigscreen-launcher-quit-ui.swift` force-unwraps the app process; add
   a clean missing-process guard before reusing it. Its generated targeted key events are not
   reliable proof of Carbon global-hotkey delivery; use System Events for Shift–Home, as in the
   earlier focus validation. Never reuse `session-running.json` against a new process identity.

## Remaining v1 work and acceptance

- Finish the full audit against every retained PRD requirement and accepted plan correction;
  produce a requirement/evidence table. Do not mark v1 complete from green unit tests alone.
- The plan proposes a delayed-launch state after 60 seconds with Keep waiting/Stop/View logs;
  the PRD and designer guidance specify no hang timeout and an indefinite spinner/exit escape
  hatch. Reconciled in this pass: retain the PRD/design behavior; the 60-second proposal is not
  adopted. Do not claim that state exists or infer crashes from elapsed time.
- Architecture/focus audit: `Focus` has logical grid/repeat/viewport helpers and model-owned
  navigation, not the retained generic focus-tree/nearest-geometry engine. Artwork loading now
  lives in a separate SwiftPM target; App retains its NSImage/memory adapter. Finish the focus
  implementation and check the remaining memory-cache boundary against the retained requirements.
- Physical DS4/TV acceptance: onboarding after desktop prerequisites, hold-PS global exit,
  no controller input leakage to the launcher while playing, disconnect/reconnect focus,
  every action/modal/log accessible, display selection/fullscreen/return at 1080p and 4K.
- Measure actual compositor/frame pacing with 600+ games and cold/warm artwork caches. Existing
  600-request cache and 720-game model CPU tests do not prove the 60 fps requirement.
- Exercise physical volume disconnect/reconnect and interrupted network/auth/account-switch
  behavior without risking active user work. Use disposable fixtures where possible; preserve
  real originals/settings/saves. Confirm resumable download and Cloud recovery gates at their
  full required scope, not just a narrow fixture result.
- BioShock Infinite prerequisites passed, but a fresh complete gameplay run remains open.
- Keep the README/plan/validation notes current, then complete the release acceptance matrix.

## Save/runtime preservation

A Short Hike currently uses installation ID `EBF6BFD4-4025-4CC8-862B-8813D8993B1B`, game files at
`/Volumes/VM/GameNative/games/gn-steam-1055540/game`, and runtime
`~/Library/Application Support/CrossOver/Bottles/gn-steam-1055540`.

An earlier whole original runtime was retained during the recovery test. Its authoritative
backup path is in `.build/runtime-recovery-live/recovery.json`, under Big Screen's private
Diagnostics directory. **Keep that backup; do not restore it over the current runtime**, whose
save progress has advanced. The last independently verified Cloud revision was 4; obtain a
fresh read if a later test needs current remote state.

## User scope decisions to preserve

- App name is **Big Screen**. Polished UI and matching the design are priorities.
- Steam Cloud sync is v1. Optional local save retention is deferred, not a Keep saves checkbox.
- v2: optional native macOS builds and discovery/integration of official Steam macOS installs.
  Never enforce native builds simply because they exist.
- CrossOver + Steam are the current focus. Other engines and stores are future work; do not
  promise all such integrations for v2.
- Preserve existing authorized work and commit progress. Do not keep asking for approval for
  routine reversible implementation steps once the user resumes.

## Commands (after resumption)

Use `./scripts/test.sh` for package + app tests, `./scripts/build.sh` for signed build, and
`./scripts/run.sh` for normal quit/staging/launch. Do not run build/test/snapshot/restart together.
Do not replace a staged bundle while its game is running. The run script refuses replacement
if normal shutdown does not complete; with the new quit confirmation an active game requires
interactive handling before staging, which is intentional.

Snapshots: `BIGSCREEN_SNAPSHOT_DIR=... ./scripts/snapshot.sh --snapshot-screens ...`; add
`--snapshot-width 3840 --snapshot-reduced-motion` for 4K. Native capture is needed for AppKit
controls; offscreen SwiftUI snapshots alone do not verify them.
