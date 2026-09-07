# Big Screen — v1 implementation plan

Written 2026-09-07 following review of [the PRD](prd/README.md), the sibling Swift implementation,
and the installed CrossOver command-line help. This is an implementation proposal, not evidence
that a title or integration already works. Implementation started with a native design preview on 2026-09-07; see the progress note below.

The delivery sequence is: prove controller-driven CrossOver launch and exit, establish durable
state and shared contracts, complete one real install/play/save/reinstall journey, then complete
the v1 interface and acceptance matrix. Home remains in v1; the background helper remains in v2.

## Implementation progress — 2026-09-07

The user prioritized fidelity to the new designer handoff and asked for incremental commits.
An initial UI pass precedes the original M0 integration sequence: native Home, Library, split game
page, Downloads/Settings previews, shared focus treatment, fonts, search keyboard and panels.
The preview uses isolated fixtures and does not connect Steam or CrossOver. Domain, logical grid
focus and foreground controller input are separate package targets. Native screenshots can be
captured for visual review. This is partial M1/M5 work, not completion of either milestone.

The follow-up UI pass fixes keyboard tab switching, download navigation and focus-driven scrolling
(including trigger paging back to the first Library row). Details animate on arrival/return; Home's
ambient artwork waits 400 ms before crossfading. Reduced motion skips transitions. Collection
create/rename/delete/membership/pinning, compatibility notes, controller text cursor/symbol entry,
and preview queue reorder/cancel/install confirmations are implemented with session-local state.

At that UI checkpoint, M0 real-game/controller handoff, first-run auth, install/session services and
remaining v1 actions were outstanding. The user confirmed DS4 foreground input works on 2026-09-07;
background game handoff is still unverified. Validation: Xcode build, five package tests and sixteen
app tests, plus native window captures at 1920×1080 and 1280×720 logical sizes (Retina pixel output).
The newer captures include paged Library return, queued download focus, collection/text editing,
compatibility notes, uninstall confirmation and the empty log viewer. A native keyboard-event
check exercised Tab/Shift-Tab, Command-2/3, Downloads up/down and Library paging back, and captured
detail/ambient transitions during and after animation. Focus-settled artwork prefetch and late-art
fades avoid a hard image pop on opening details. See the root README for reproducible commands.

A subsequent foundation pass adds the GRDB/SQLite Catalog with transactional source/local separation,
collections, preferences, installations, durable job records and exact-once session checkpoints.
Interactive preview edits now survive restart in an isolated preview database. Nine Catalog tests,
four app persistence tests, and the previous twenty-one tests pass (34 total). A native keyboard/
process restart check verified persisted favorites and restored the original value.

The CrossOver probe created/cloned/deleted owned Windows 10 bottles, verified MSync/D3DMetal settings,
and ran a Windows command. Missing-executable invocation hung even with `--no-gui`; Runner must
preflight paths and provide recoverable delayed launch. This is a recorded failure, not a passed M0
gate. See [foundation/platform evidence](validation/2026-09-07-foundation.md). Chunk-resumable jobs,
actual game sessions, background exit input, and release acceptance remain open.

The M2 account/catalog slice is now connected to the native UI. Normal launches use the real SQLite
catalog; `--preview` explicitly selects the isolated design fixtures. QR, password/Steam Guard,
cancel/retry and logout use injected Keychain storage, with no CLI credential-file fallback. Owned
library refresh commits before optional metadata enrichment, preserves cached data on failure, and
keeps focus by stable game ID. Startup/manual/six-hour refresh and actual source play history are
wired into Home/Library/Settings. Compression libraries are embedded; the app target is macOS 15
because the available Homebrew binaries require it. Execution remains verified only on macOS 26.6.2.

The unauthenticated Steam QR challenge and public metadata probe passed. Native sign-in snapshots,
24 app tests and 22 package tests passed (the optional network test was run separately). Full account
approval, a real 600-title library and authenticated offline restart remain unverified. This does not
complete the M2 gate or v1: installer, runner/session services, setup and remaining UI acceptance are
still pending. See [account validation](validation/2026-09-07-steam-account.md).

The next setup slice adds a Runner command executor with bounded output, process-group cancellation
and timeouts, plus owned, versioned CrossOver template preparation and persisted failures. A real
unique template was created, checked with a Windows command, reopened from its receipt and deleted
successfully. The Installs module now provides writable local-volume selection, a real write check,
bookmarks and stable-volume resolution; the durable download orchestrator remains pending.

The native first-run path now includes pairing guidance with highlighted Share/PS controls, optional
display selection, account sign-in/skip, games volume, template progress/failure/retry and completion.
These controls are also reachable from Settings. Display choice and setup completion persist; a
controller-disconnect banner preserves focus. Actual game launch and background input are still
unverified. See [setup/runtime evidence](validation/2026-09-07-setup-runtime.md).

The latest UI slice completes the native controller button-test screen and grouped library
Sort & Filter sheet, including every v1 sort, combined refinements, persistent selections and
keyboard-aware footer hints. Seventy tests pass, with two optional probes skipped; native
keyboard navigation and window captures were checked. New diagnostic hardware validation remains
pending. The sibling SteamCore commit `b54c993` supplies durable, verified chunk checkpoints with
nine new resume tests, but the app's durable install orchestrator is not yet connected. See
[controller/filter and downloader evidence](validation/2026-09-07-controller-filters.md).

SteamCore `4d5a46e` now bounds CM request waits, cancels them on disconnect, isolates stale connection
replies, injects depot-key storage, and preserves PICS launch/save metadata. The native account
boundary cancels authenticated work on sign-out and uses memory-only depot keys. The live unauthenticated
CM hello and expanded suites pass. The installer factory, pinned plan and durable orchestration remain
the next integration work; see [installation boundary evidence](validation/2026-09-07-steam-install-boundary.md).

## 1. Planning defaults and PRD corrections

Use these defaults to make the work concrete. Reconcile the referenced PRD requirements during
M1; record any changed product decision explicitly rather than silently reducing v1 scope.

| Topic | Planning default / correction | Requirements |
|---|---|---|
| Supported titles | Begin with Cuphead; evaluate A Short Hike and TUNIC as candidates. Release requires at least one explicitly verified title completing every acceptance step. Display the full owned library without implying universal compatibility. | README MVP bar |
| Exit control | Attempt PS-hold first. A tested controller chord is a proposed fallback if the OS/controller combination prevents reliable PS-hold. Record that mapping change before release if needed. | FR-IN-3, FR-INGAME-1/2 |
| Input modes | Separate launcher, game, and exit-overlay modes. The overlay accepts navigation and confirmation while a game runs. In game mode, short PS is ignored; PS-hold opens the exit overlay. | FR-IN-3, FR-INGAME-1/2 |
| Download resume | Implement persistent chunk resume as written in the PRD. Existing SteamCore only resumes completed files. Completed-file resume is a possible scope reduction, not the planned acceptance bar. | FR-INST-3/6 |
| Verification | Verify depot originals before modifications. Track modified files and validate staging separately. Repair uses the installed manifest and reapplies staging. | FR-INST-8/9 |
| Launch delay | After a configurable launch threshold, show a recoverable delayed-launch state with Keep waiting, Stop, and View logs. Do not infer a crash solely from elapsed time. Start with 60 seconds and tune against verified titles. | FR-LAUNCH-2/3, FR-FAIL-1 |
| Return destination | Return to Home after game exit; retain the just-played tile as focus when visible, otherwise use the normal Home fallback. Launch failures return to the game page. | FR-HOME-1, FR-EXIT-1 |
| Empty Home | Show a focused Browse library action, or Sign in when appropriate, if no rows have content. | FR-HOME-1/2, FR-DONE-1 |
| Save retention | Deferred to a future version by the user. v1 uninstall explains local save deletion and resolves pending Cloud uploads before removal; reinstall restores synchronized saves from Cloud. No Keep saves option in v1. | FR-UN-1/2/4 |
| App quit | While playing, normal Quit offers Keep launcher open or Quit game and launcher. With downloads only, checkpoint/pause jobs and quit. Recover separately from unexpected launcher termination. | AR-PROC-1, FR-INST-6 |
| Account policy | One device-local player profile in v1: installs, saves, ratings, collections, and local play history survive logout. Logout clears credentials and the source-owned library/identity cache. Retained local installs remain visible for offline play; downloads require authentication. Signing in to another account does not create separate saves. | FR-AUTH-3/4, AR-STOR-1 |
| Themes | Dark is the v1 implementation baseline. The designer brief's light-theme deliverables do not create an untagged v1 theme-switcher requirement; reconcile the brief explicitly. | GUI_DESIGN_BRIEF |

Additional corrections: pin a concrete macOS/Xcode/Swift/CrossOver baseline during M0; distinguish
installation failure from the user's Broken compatibility rating; show Verify files in an actual
controller-accessible action menu; define “recently added” as first observed by this launcher;
separate imported Steam playtime from locally recorded sessions so sync cannot double-count or
overwrite local time. Pairing and installing/licensing CrossOver are desk prerequisites; measure
the two-minute onboarding goal after those prerequisites, under a documented network condition.

## 2. Existing code: reuse and required work

Only link the sibling package's `SteamCore` library product. Do not import `steamcli` or
`GameNativeRuntime` to obtain convenience functions.

| Area | Evidence at review | Planned work |
|---|---|---|
| Authentication | SteamCore has QR/credentials paths; `SteamAuth` directly persists through `TokenStore.save`. | Inject credential persistence inside SteamCore; supply a Keychain implementation from Sources. Test that the app path never writes auth JSON. Preserve CLI behavior through its existing/default adapter. |
| Downloads | `DownloadEngine` skips completed files by size and rebuilds partial files; progress is per depot. | Add durable chunk checkpoints, cooperative cancellation, manifest selection/persistence, aggregate progress, and explicit pause semantics. |
| Depot selection | `selectDepots` skips shared redistributables and DLC depots. | Add a CrossOver prerequisite plan and verified entitlement handling. A metadata DLC list is not ownership proof. No DLC-management UI is required in v1. |
| Metadata | `AppInfo` exposes depot/install/UFS data, but no executable launch entries, genres, controller support, or descriptions. | Extend parsing/adapters where available; document any additional source endpoint. Missing fields remain unknown rather than guessed. Load owned games before enriching metadata. |
| Steam emulation | SteamPreparer bundles/checks gbe_fork assets, replaces DLLs with backups, and reports SteamStub requirements. | Reuse staging primitives, assemble cached offline metadata in Sources, and implement a versioned Steamless invocation where required. Handle games without a Steam API DLL as a distinct case. |
| Launch selection | CLI launch/config helpers live outside SteamCore. | Implement source-neutral launch resolution; use Windows launch metadata and internal title recipes, with explicit ambiguity failure. No arbitrary “first exe” fallback. |
| Build dependencies | The Swift package declares macOS 14 and uses liblzma/libzstd system libraries. | Validate the actual minimum and arrange runtime library/resources delivery for the app. Distribution polish remains deferred, but the app must find its required libraries. |

Source references: [Package.swift](../../GameNative-macos/swift/Package.swift),
[DownloadEngine.swift](../../GameNative-macos/swift/Sources/SteamCore/DownloadEngine.swift),
[PICS.swift](../../GameNative-macos/swift/Sources/SteamCore/PICS.swift),
[SteamAuth.swift](../../GameNative-macos/swift/Sources/SteamCore/SteamAuth.swift),
[Prepare.swift](../../GameNative-macos/swift/Sources/SteamCore/Prepare.swift), and
[CLI Mode A orchestration](../../GameNative-macos/swift/Sources/steamcli/ModeAStaging.swift).

SteamCore changes are a separate dependency deliverable in `GameNative-macos`, with targeted
regression tests and a recorded compatible commit. Keep this repository's local-path dependency
and document the sibling checkout requirement.

## 3. Architecture and durable contracts

### Modules

Create one Xcode app target and a local Swift package with these targets. Add targets with their
first real implementation rather than populating an empty framework in advance.

| Target | Ownership | Dependencies |
|---|---|---|
| Domain | Stable IDs, source-neutral models, service protocols, job/session snapshots, failure values | Foundation |
| Catalog | SQLite migrations and repositories; sole owner of durable app-state writes | Domain, GRDB |
| Input | Hardware events, semantic mapping, repeat/deadzone, connection state, glyphs | Foundation, GameController |
| Focus | Geometry, focus containers, stable item IDs, modal stack, focus memory | Foundation |
| Sources | GameSource/Installer implementations, Keychain adapter, Steam translation and staging | Domain, SteamCore |
| Runner | CrossOver capabilities, templates, bottles, process/session supervision | Domain, Foundation |
| Installs | Install/repair/uninstall job scheduling and recovery | Domain, Catalog, Sources, Runner |
| Sessions | Launch orchestration, session persistence, download pause coordination, post-exit recovery | Domain, Catalog, Sources, Runner, Installs |
| Artwork | Fetch, bounded disk/memory cache, cancellation and placeholders | Domain, Foundation |
| BigScreenApp | Views, AppKit presentation, dependency wiring, input-mode coordination | Targets above |

`Sessions` owns the ordering between installer preparation and runner launch; Runner never calls
back into a source. UI commands go through injected install/session service protocols. Use
`Sendable` value snapshots, stable IDs and reconnectable observations so v2 can add XPC adapters;
do not implement IPC or claim that Swift streams themselves are XPC contracts in v1.

### Models and operations

- Use `(sourceID, sourceGameID)` as game identity; keep install, job, and session IDs separate.
- Persist source catalog data independently from local edits, install records, and compatibility.
- Install records include volume identity and relative path, depot manifest IDs, selected language,
  template/recipe/staging versions, launch spec, ownership marker, and mutation/backup records.
- Jobs expose start, pause, resume, cancel, retry, reorder and observe-by-ID. Observing progress
  must not create work; closing a screen must not cancel a job. Define cancellable boundaries for
  each stage and expose “Stopping…” while a noninterruptible operation settles.
- Serialize mutating jobs in v1; skip blocked/paused jobs so another eligible job can run. Hold a
  per-game lock across install, repair, uninstall, and play. Permit only one active game session.
- Track pause reasons as a set: user, gameplay, authentication, unavailable drive, insufficient
  space. Removing the gameplay reason must not remove another reason.
- Use one transactional SQLite source of truth for app state. Optional JSON is a versioned recipe
  or export, not a second writable copy of database state. Filesystem checkpoints are reconciled
  with the database after interruption.

### State and UI contract

Keep install state, job state, run state, drive availability, and compatibility rating separate.
Publish a single derived presentation snapshot for each game; all screens use the same values.

| Condition | Primary action / presentation |
|---|---|
| No installation | Install, or an explicit prerequisite/authentication action |
| Queued | View download; queue position |
| Downloading/preparing/verifying | View progress; stage-specific pause/cancel availability |
| User-paused | Resume download |
| Blocked | Resolve the named cause; retained progress |
| Failed install/repair | Retry and View logs; play availability depends on validated install state |
| Installed and available | Play |
| Drive disconnected | Reconnect drive; Play disabled |
| Launching/delayed launch | Launch status and Stop; delayed state also offers Keep waiting |
| Running | Return to game |
| Uninstalling | Removal progress; Play disabled |

Every empty screen and disabled primary action needs a valid focus fallback. Hiding/removing a
focused game, refreshing a list, changing filters, and virtualizing tiles must preserve or
deterministically relocate focus. Navigation uses logical grid geometry even for unmounted views.

### Install, repair and uninstall transactions

Install pipeline:

`Resolve recipe/manifests → Estimate/confirm/reserve → Download → Verify originals →
Prepare bottle/prerequisites → Stage emulation → Validate launch configuration → Commit installed`

- Account for games-volume bytes, partial downloads/backups, bottle-volume bytes, and save-backup
  space separately. Reservations are app accounting, not an OS guarantee; recheck before writes.
- Store volume identity rather than trusting a mount path alone. Define supported writable local
  filesystem types from M0 testing. Existing installs on earlier selected volumes stay tracked.
- Persist chunk completion only after the corresponding data is durable; validate checkpoints
  against manifest identity. Persisted manifests prevent a restart from silently selecting an update.
- Make every stage safe to retry. On startup inspect ownership markers and outputs, reconcile
  checkpoints, then continue at the first incomplete or invalid stage. Never blindly trust a
  “completed” flag or repeat destructive work solely because a flag was not committed.
- Maintain original and transformed-file integrity separately. Repair originals using the pinned
  manifest, refresh affected backups, reapply modifications, then validate launch readiness.
- Cancellation removes only resources created/owned by that new install. Canceling a repair must
  not uninstall an existing game. Canonical path containment, symlink handling, and ownership
  markers govern deletion; a matching bottle name alone is insufficient.
- Uninstall acquires the game lock, stops the session, resolves pending Cloud uploads, removes owned
  files/bottle, then clears install state. Failed sync requires retry or explicit confirmation to
  discard unsynced progress. Partial removal remains a recoverable job. Local uninstall archives
  and restore are deferred; reinstall uses pre-launch Cloud sync with normal conflict handling.

### Session lifecycle

- Persist session ID, bottle identity, observed processes with identity checks beyond PID alone,
  timestamps, and outcome. Reconcile live sessions before restarting queued work on app launch.
- Evaluate `cxstart --wait-children` and window-to-process attribution in M0; a wrapper PID exiting
  must not end a session whose game child still runs. Lingering Wine services must not keep a
  finished session alive indefinitely.
- Define launching, running, delayed, stopping, exited, failed and interrupted states. A first
  relevant window is a presentation signal, not proof of player-controlled gameplay.
- Attribute foreground activation, cursor visibility and overlay dismissal explicitly. Opening an
  overlay must not assume it pauses the game or suppresses its controller events; prove behavior.
- Attempt the validated graceful-close mechanism, wait up to 10 seconds, then terminate only the
  owned bottle's processes. Force termination is recorded as forced, not crash.
- Record clean, crash, forced, launch-failed or unknown/interrupted outcomes using evidence. A
  short clean session is still clean. Use monotonic duration within a live process and bounded
  durable checkpoints for recovery; do not charge launcher downtime as playtime.

## 4. Milestones and completion gates

Each milestone should produce reviewable code and its validation evidence. Split by the
deliverables below; do not estimate the complete schedule until M0 has resolved feasibility and
the upstream work has been sized.

### M0 — Prove the actual platform path

Dependencies: installed CrossOver, connected DS4, TV, and access to a candidate game.

- [ ] Record hardware, macOS, Xcode/Swift, CrossOver version/path/license state and supported display modes.
- [ ] Build a minimal native harness: controller event display, fullscreen launcher window, and exit dialog.
- [ ] Validate PS short/hold delivery while backgrounded, relevant OS controller settings, disconnect/reconnect,
  overlay focus and input leakage, game activation, and return to the selected display.
- [ ] Create/copy/delete a throwaway owned bottle using explicit `--bottle`; verify MSync/D3DMetal settings
  and actual prerequisite needs. Capture command arguments and outcomes without credentials.
- [ ] Launch a trivial Windows process and a real candidate; exercise child handoff, clean quit, forced quit,
  missing exe, delayed/no-window launch, and a second unrelated bottle that must remain unaffected.
- [ ] Locate the candidate's saves/config and demonstrate backup/restore. Check whether bottle mappings
  redirect save paths outside the bottle or into the game directory.
- [ ] Record required macOS permissions/system setup and test the intended games-volume filesystem.

Gate: a controller can launch, control and exit at least one candidate on the TV, and scoped process
supervision is demonstrated. If the overlay cannot avoid unsafe input leakage, revise that interaction
before building the full UI. Deliver a feasibility note with observed results and reproducible commands;
do not promote a candidate to Works based only on a window appearing.

### M1 — App foundation, contracts, input and persistence

Dependencies: M0 results.

- [ ] Reconcile PRD corrections/defaults in section 1, including the designer brief.
- [ ] Establish Xcode app/local package, documented build command, dependency baseline and runtime resources.
- [ ] Add Domain contracts, Catalog migrations, structured redacted failures/logs, and injected fake services.
- [ ] Implement Input timing/deadzone, cardinal-action resolution for diagonal stick input, glyph fallbacks,
  mode transitions, and long-press behavior that does not also trigger short press.
- [ ] Implement Focus containers, column memory, handoff, modal stack, scrolling and missing-item fallback.
- [ ] Build display selection/persistence, disconnect fallback, safe-area scaling, reduced motion and shell tabs.
- [ ] Build a reusable modal/dialog and basic on-screen keyboard for subsequent setup and search screens.

Gate: controller-only navigation works on a fake Home/library, including empty states, keyboard/modal
focus and reconnect. Focus geometry and synthetic input tests cover FR-FOCUS-1–7 and FR-IN-1–3.
Catalog migrations and interrupted-job reconstruction are tested without the UI.

### M2 — Real Steam account and catalog

Dependencies: M1; SteamCore authentication and metadata changes.

- [ ] Implement injected Keychain persistence end to end; isolate app storage from the sibling CLI.
- [ ] Implement QR waiting/approved/expired/network states, cancellation, password/Guard fallback and logout.
- [ ] Load/cache the owned library; preserve it on transient sync failures and support offline startup.
- [ ] Add progressive metadata enrichment with bounded concurrency, retries/backoff and unknown values.
- [ ] Implement source-provided artwork descriptors, lazy artwork cache, placeholders and bounded eviction.
- [ ] Persist favorites, hidden status, collections, compatibility notes and local playtime independently.
- [ ] Add Windows launch/depot resolution and cached verified entitlement data needed by M3.

Gate: a real 600-title library loads progressively with keyboard-free sign-in, artwork and offline
restart. Logout follows the selected policy. Recorded fixtures cover mapping and errors; auth tests
verify no credential file is produced and no secret appears in captured diagnostics.

### M3 — Durable install and repair engine

Dependencies: M1/M2; upstream chunk-resume work; M0 bottle/prerequisite findings.

- [ ] Implement versioned internal title recipes: executable selection, prerequisite actions, runner settings,
  launch args/env and save mappings. Editing properties stays v2; execution of required recipes is v1.
- [ ] Implement estimates/confirmation, per-volume reservations, serial queue, reorder and shared progress.
- [ ] Implement pinned-manifest download/checkpoints and per-stage pause/cancel/retry behavior.
- [ ] Implement template versioning and bottle creation with ownership checks and recoverable checkpoints.
- [ ] Integrate prerequisites, gbe_fork, synthetic offline identity and Steamless where detected/required.
- [ ] Implement original-file verification, mutation records, launch-readiness validation and repair.
- [ ] Implement startup reconciliation, drive reconnect, authentication expiry and disk-full recovery.
- [ ] Wire minimal game-page and Downloads progress/actions; reuse those components in M5.

Gate: a candidate installs without the CrossOver GUI, survives interruption within a large file and
between every stage, and repairs a missing/corrupt file without losing emulation changes. FakeInstaller
tests inject failures at each stage and around completion commits. A FakeSource exercises materially
different metadata/auth/capability behavior through the same pipeline, not just a renamed Steam fixture.

### M4 — Complete play, saves and reinstall for one title

Dependencies: M3; M0 process/input validation.

- [ ] Implement Sessions orchestration, installed-state checks, missing-bottle recovery and offline launch.
- [ ] Implement launch/delayed/error states, window handoff, exit overlay, graceful/forced stop and Home return.
- [ ] Implement single-session enforcement, playtime/outcome recording, automatic pause-reason coordination,
  normal app quit, launcher-crash reconciliation and prevention of duplicate sessions after restart.
- [ ] Implement controller uninstall confirmation with local-save deletion consequences, pending Cloud
  upload handling and partial-removal recovery. Local save retention is deferred.
- [ ] Ensure missing-bottle recreation reapplies the recorded recipe and synchronizes available Cloud saves.
- [ ] Implement Steam Cloud metadata/transfer adapters, verified save-path mapping, account-scoped
  sync journals, pre-launch pull, post-exit push, offline retry and controller conflict resolution.
- [ ] Verify cloud roundtrip, concurrent edits, interrupted transfer/restart, account switching and
  pending-upload retry/discard confirmation during uninstall and Cloud restore after reinstall.
- [ ] Evaluate candidate titles and document which are verified, unsupported or still unknown.

Gate: from fresh game state, install → player-controlled gameplay → save → quit → offline relaunch →
successful Cloud upload → uninstall → reinstall → Cloud download → load the same save succeeds using only the controller after
setup. Test quitting within 30 seconds, child-process handoff, force quit, and launcher restart while
a game survives. Session completion and playtime are recorded once.

### M5 — Complete the v1 couch interface

Dependencies: M2–M4 services.

- [x] Replace or normalize PlayStation button glyphs so Circle and Square have comparable optical
  size and stroke weight to Cross and Triangle. Check footer hints, action buttons and focused states
  at 1080p and 4K; use consistent vector symbols rather than relying on mismatched font characters.
  Requested by the user on 7 September 2026.
- [x] Make cursor visibility follow the active input device: mouse movement/clicks reveal and keep
  the pointer usable; controller/keyboard navigation can hide it. Do not capture or lock the mouse
  in the launcher. Verify clicks do not immediately hide it, repeated input changes balance AppKit
  hide/unhide calls, and focus loss restores normal desktop behavior. Requested 7 September 2026.
  Both changes implemented and checked in `docs/validation/2026-09-07-input-polish.md`; physical
  controller/game handoff remains part of the wider TV acceptance run.

- [ ] Finish first run: pairing guidance, display/volume choice, sign-in/skip, CrossOver retry and template progress.
- [ ] Finish Home rows, empty fallback, persistent tabs/legend/download indicator and exit focus behavior.
- [ ] Home: navigating Up from the games focuses the top tabs; Left/Right then switches tabs.
  Requested by the user on 7 September 2026.
- [ ] Limit Continue playing to 15 game cards, followed by a Library card that opens the full
  Library. The Home row must end there rather than scroll indefinitely. Requested 7 September 2026.
- [ ] Finish Library rail/grid, sorting, filters, live search, hidden-only visibility and collection management.
- [ ] Finish game page metadata/actions, all install/run states, compatibility editor and Verify files entry point.
- [ ] Finish Downloads queue/reorder/history, storage breakdown and actionable retained failures.
- [ ] Finish keyboard shortcuts/password masking, contextual actions, confirmations and controller glyph legends.
- [ ] Finish Settings: account/refresh, download toggle, volume/display/reduced motion, button test, versions,
  log viewer/Finder action and reset. Reset preserves games/saves by default and requires explicit consequences.
- [ ] Make transient toasts informational; durable failure actions remain accessible without chasing a disappearing toast.
- [ ] Bound/redact per-job/session logs and rotate to the last 10 per game; keep technical names in diagnostics.

Gate: every v1 user journey and error action is reachable from the DS4. Snapshot all screens at 1080p
and 4K with reduced motion. Test live data changes, hidden focused games, empty filtered results, and
controller reconnect. Measure 600+ title scrolling on the recorded target hardware with cold and warm artwork caches.

### M6 — Release acceptance and handoff

Dependencies: M0–M5 gates passed.

- [ ] Run the acceptance matrix below and record versions, title/build IDs, outcomes and relevant log locations.
- [ ] Verify the app can run with its required resources/libraries without relying on the development shell's environment.
- [ ] Check every v1 requirement against its implementation and evidence; unresolved items are recorded failures or
  explicit scope decisions, not silently marked complete.
- [ ] Document build/run instructions, required sibling commit, CrossOver/system setup, supported-title results,
  known limitations and recovery steps. Prove the v1 cloud-save gates separately; do not claim updates or general game compatibility.

Gate: README's corrected MVP bar and all retained v1 requirements pass. A skipped CrossOver integration
test on a machine without CrossOver cannot satisfy the real-platform release gate.

## 5. Acceptance matrix

| Area | Required evidence |
|---|---|
| Setup | Fresh app, QR expiry/retry, credential fallback, skip, missing/unlicensed CrossOver, selected display absent; timed onboarding under recorded prerequisites/network |
| Controller/focus | DS4 Bluetooth, repeat/deadzone/diagonal behavior, disconnect/reconnect, modal traps, removed items, virtualized grid, background exit activation and overlay input leakage |
| Catalog/UI | 600+ titles, progressive art/metadata, offline cache, failed refresh preserves data, hidden/collections/search, 1080p/4K snapshots and measured frame pacing |
| Download | Mid-file process termination, chunk integrity/checkpoint recovery, queue reorder, user-vs-gameplay pause reasons, cancel cleanup, auth expiry, network loss, disk full and drive removal |
| Install/repair | Failure/crash around each commit boundary, partial bottle clone, prerequisites, SteamStub handling, originals vs transformed integrity, pinned manifests, no silent updates |
| Session | Relevant window vs splash, no-window delay, child handoff, normal/early/forced exit, hanging close, one game at a time, restart reconciliation and exact-once history |
| Cloud/uninstall | Cloud save restored after reinstall, unsupported mapping, failed upload blocks removal until explicit discard, partial removal retry, sync conflict, game-local saves, unrelated bottle untouched |
| Storage/privacy | Volume rename/remount, separate game/bottle/backup capacity, path/symlink containment, app-owned deletion only, logout/reset semantics, Keychain-only auth and log redaction |
| Extensibility | FakeSource/FakeInstaller run through unchanged UI/orchestration; only Sources imports SteamCore; services expose durable IDs and value snapshots |

Run focused unit/integration tests with the milestone that introduces the behavior. Manual TV and
CrossOver evidence complements those tests; snapshots do not prove navigation or gameplay. Broaden
testing when an integration change creates a new concern, then run the full matrix once for release.

## 6. Deferred work and scheduling boundary

Keep these out of the v1 critical path: background helper/XPC implementation, a second real store,
user-editable per-game properties, updates, achievements UI, optional native macOS games and official
Steam macOS installation integration, Quick Access features,
controller remapping, kiosk/power management, community compatibility, and distribution/notarization polish.

The main scheduling uncertainties are M0 background input/window behavior, upstream chunk resume,
title-specific prerequisites/Steamless, and safe save discovery. Size these after their evidence is
available. The first complete real-game journey is the M4 checkpoint; completion of that checkpoint
does not replace M5's remaining v1 features or M6 acceptance.

Platform reference: Apple's [background controller monitoring documentation](https://developer.apple.com/documentation/gamecontroller/gccontroller/shouldmonitorbackgroundevents)
describes background event delivery; it does not establish that an overlay can exclusively route
input away from a CrossOver game. That behavior remains an M0 test.

### 7 September — persistent install queue and live UI

The app now connects resolved install estimates and confirmation to a serial, persistent queue,
owned game storage/bottles, source staging and atomic installation commit. Downloads controls and
progress use saved jobs. This is a tested implementation checkpoint, not completion of the real-game
or v1 gates. See [queue and UI evidence](validation/2026-09-07-install-queue.md) for checks and remaining work.

### 7 September — real install and private Windows folders

Oniken completed the real Steam install pipeline in the signed app after replacing native-folder
links with bottle-local Windows folders. The verified download was reused on Retry. Template and
clone probes, folder ownership tests and the real installed folder audit passed. This establishes
one real installation; play/session/save-reinstall acceptance remains open. See
[private-folder and installation evidence](validation/2026-09-07-private-game-folders.md).

### 7 September — game process observation and scoped quit

The injected CrossOver runner now has literal launch arguments, bottle/process/window attribution,
scoped graceful/forced termination and process-identity recovery. A real Oniken window and ten-second
quit escalation were observed. The session service and Play/overlay UI remain unconnected, and
controller handoff/player-controlled gameplay are not yet proven. See
[runner evidence](validation/2026-09-07-game-runner.md).

2026-09-07 session service checkpoint: launch preparation, a single active game, monotonic
playtime starting at the first window, persisted runtime receipts, recovery before queue restart,
and graceful/forced quit coordination now run independently of UI subscriptions. Recreating a
runtime reruns source staging and saves the validated launch spec. Gameplay pause waits for the
install worker to release its work; user pause remains independent. Six session tests and a new
queue cancellation-boundary test pass, along with the full package/app suite. The Play button,
launching screen, background hold-Home routing and exit panel still need integration and live
validation with A Short Hike. Ambiguous launches without a saved process receipt deliberately
hold recovery and downloads pending further recovery work.

2026-09-07 session UI checkpoint: Play is connected, with mockup-based launching/exit screens,
one-game confirmation, first-window handoff, Shift–Home, background controller hold detection,
normal quit coordination and persisted session diagnostics. Fullscreen game-window attribution
and overlay ordering were corrected using a real A Short Hike launch. The suite has 121 passing
tests and three optional runtime skips. Title rendering, global keyboard overlay, forced quit and
return to fullscreen were observed; continuous gameplay, physical DS4 handoff and save/relaunch
are still open. See `docs/validation/2026-09-07-session-ui.md`. User additionally requested clear
preferred-monitor settings for launcher/game placement and a saved startup-fullscreen option;
these are the next display work, beyond the existing first-run launcher display selector.

Display follow-up: Settings now exposes the current fullscreen mode and a separately saved
startup-fullscreen preference. The launcher display picker stores a stable UUID/name, preserves
an unavailable preference, and follows the preferred display on reconnect when no game is active.
Both fullscreen monitor-switch directions and saved windowed/fullscreen startup were exercised
on the real LG and built-in displays. AppKit follow-up transitions must occur after the exit
delegate callback returns; the live check caught and fixed a stranded fullscreen Space.
See `docs/validation/2026-09-07-display-settings.md` for checks and remaining limits. Applying
the monitor preference to CrossOver game launches is still outstanding; launcher placement
alone does not satisfy that request.

2026-09-07 permission follow-up: confirmed Big Screen is already unsandboxed. Removed emulator
LAN discovery from offline preparation and updated existing generated configs after checking
installation ownership and idle sessions. This reduces an unnecessary permission trigger;
macOS privacy grants remain separate from App Sandbox and are not bypassed.


### 7 September — user scope update and current delivery priorities

Cloud save sync moved into **v1** by explicit user request. This supersedes earlier references to
cloud saves as deferred. FR-CLOUD-1–6 in PRD 05 define the sync, conflict, offline, account and
save-path requirements. Local save retention alone does not satisfy this addition. The existing
single local profile remains usable offline, but cloud journals and pending writes must be account
scoped, and an account switch cannot silently upload the previous account’s local progress.

For **v2 only**, provide optional native macOS game versions alongside Windows/CrossOver, plus
installed-game discovery and launch integration with the official Steam macOS client. A native
build must never be enforced. Installation choices and ownership stay distinct even when the
library merges them under one Steam app ID. See FR-MAC-1–4.

Local save retention was subsequently deferred to a **future version** by the user on 7 September.
The existing save-copy primitives can support Cloud transfer staging/conflict backups, but v1 does
not offer local uninstall archives or Keep saves. This supersedes earlier retention milestones.

Current priorities: implement and validate Steam Cloud sync; finish uninstall/reinstall with Cloud
recovery and explicit local-save deletion consequences; complete remaining runtime recipes,
download/storage and diagnostic UI; run the full v1 controller/TV acceptance matrix. Monitor
selection and fullscreen startup are implemented and verified; the session notification actions
now have explicit keyboard/controller hints and focus. These checkpoints do not complete v1.
