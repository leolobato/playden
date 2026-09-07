# Installation queue and UI checkpoint — 7 September 2026

The app now resolves a pinned install plan, shows its download/installed/required-space estimate,
checks available space after queue reservations, and enqueues only after confirmation. The queue
owns its worker independently of the dialog. Downloads, the game page, library tiles and the bottom
indicator read the same saved job progress. Live screens no longer display fixture percentages or
transfer speeds. Pause, resume, retry, cancellation and reordering act on the persistent queue.

## Recovery and ownership

- Plans, stable volume identity/bookmark, intended game location and ownership tokens are persisted
  before file creation. Install containers and game bottles have separate ownership receipts.
- One job runs at a time. User/gameplay/authentication/drive/space pause reasons remain independent.
  The backend supports gameplay pauses; the play-session service is not connected yet.
- Downloads, original verification, owned bottle creation, source staging and validation precede
  the atomic installation/job commit. Failed jobs retain their stage and diagnostic output.
- Cancellation stops the worker before cleanup. Cleanup checks ownership and runs in a fresh task;
  a disconnected-drive cleanup can be explicitly retried. Normal app termination awaits shutdown.
- A restart recovers interrupted jobs from saved stages and revalidates before committing. A missing
  bottle during final validation invalidates the bottle checkpoint so Retry can recreate it.

## Evidence

- `./scripts/test.sh`: 55 package XCTest cases (3 optional probes skipped), 5 focus tests and
  40 app tests: **97 passed, 3 skipped**, no failures.
- Six queue tests exercise a non-Steam, offline source with nonnumeric IDs, actual temporary files,
  atomic catalog commit, serial ordering, persistent reorder, independent pause reasons,
  cancellation cleanup, restart after staging failure and storage ownership rejection.
- Five app tests exercise estimate/confirmation, insufficient space, cancelling resolution,
  Downloads navigation and cancellation confirmation, independent resume reasons, and library
  refresh retaining an unfinished job's status/action.
- The native screenshot command renders `install-offer`, `install-offer-space`, `install-queue`
  and `install-game-progress`. Captures are in `.build/install-queue-ui/`; these are explicitly
  isolated fixtures with no account, catalog, queue worker or game files. Screens were opened for
  visual inspection. A game-page/footer overlap and incorrect live Downloads action hint were fixed.
- Per-game CrossOver clone/startup/delete was also tested against CrossOver 26.2 (opt-in
  `GameBottleTests` probe, 4 passed). This proves bottle setup, not game playability.
- After the user approved macOS Keychain access, the signed app refreshed **538 owned games**;
  the local source-sync checkpoint is `2026-09-07 17:00:25.659` UTC.

## Live Steam install probe

After launching the signed app from its isolated Run bundle, keyboard navigation opened Oniken
(Steam app 252010) and resolved its real Windows plan: 32.7 MB download, 35.9 MB installed,
372.5 MB required. Confirmation queued the game, downloaded all 35,940,746 uncompressed bytes,
and passed original-file verification. No extra Keychain prompt was needed after the user's grant.

CrossOver's clone/restore then attempted its default Desktop folder integration. macOS displayed
an independent Desktop-access prompt. The administrative command hit its 120-second deadline;
the queue retained the verified download and failed at `createBottle`, with a retry action and
bounded diagnostic output. No installation record was committed. This is useful live failure and
recovery evidence, not proof of a completed install. The prompt was not granted automatically.
Runtime folder isolation needs follow-up so game setup does not depend on personal Desktop access.

## Remaining v1 work

This checkpoint does not establish a real game installation or playable session. Steamless,
prerequisite/title recipes, repair of transformed originals, uninstall/save retention, play-session
supervision, controller handoff and external-drive interruption still require implementation and
real-game evidence. The Downloads storage utilization bar, measured transfer speed/ETA, and history
dismissal remain open. Progress currently reports uncompressed content written, explicitly labelled
as such; it is not presented as network throughput. The PRD acceptance gates stay open.
