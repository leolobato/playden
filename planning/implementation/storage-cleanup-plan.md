# Storage cleanup — commit plan

A PS5-style "free up space" screen in Settings › Library. Branch: `feat/storage`. Commit each step
once it builds and its tests pass. Mark steps done here and commit this file with them.

## Behavior

- Settings › Library gets a **Storage** row right after "Games volumes" (rows below shift by one).
- It opens a wide sheet. The top lists the connected games volumes as cards (name, used/free bar,
  "X free of Y"). The focused card picks the volume whose games are listed.
- Each installed game on that volume is a row: checkbox, cover, title, size and last played.
  Size comes from `InstallationRecord.installedBytes`; last played from `CatalogEntry.lastPlayedAt`.
- Sort: **Size** (largest first, default) or **Last played** (never played first, then oldest).
  A segmented control in the list header switches it; Options toggles it too. L1/R1 switch volume.
- Not selectable, with the reason shown: the game that is running, games with an active job
  (download, verify, removal), and This Mac apps (they are the user's files and never listed).
  Disconnected volumes are not listed, so their games are not offered.
- The footer shows "Delete N games · frees X" once something is checked. Delete asks once for the
  whole batch.
- The batch reuses the single uninstall checks for each game, one by one: sync Cloud saves, review,
  queue the removal. Games whose saves could not be synced are not removed silently (FR-UN-4). After
  the batch they open in the existing uninstall dialog one at a time, so the player decides.
- When the batch queues games, Playden switches to Downloads like a single uninstall.

## Step 1 — Extract uninstall preparation

- [x] `prepareUninstall(_:)` returns an authorization or "needs a decision", shared by
  `activateUninstall` and the batch. Existing `UninstallInteractionTests` keep passing.

## Step 2 — Model

- [x] `App/StorageCleanup.swift`: `Panel.storage`, volume and game rows, sort, selection,
  focus/input, batch delete and the follow-up queue of games that need a decision.
- [x] Settings row at Library index 2; update `activateSetting`, `move`, snapshots and tests.
- [x] `Tests/AppTests/StorageCleanupTests.swift`: sorting, eligibility, batch queues clean games and
  hands unsynced ones to the uninstall dialog.

## Step 3 — View and snapshots

- [x] `App/StorageCleanupViews.swift` and the `ModalLayer` branch.
- [x] `settings-storage` and `settings-storage-confirm` snapshot screens; review the captures.

## Step 4 — Docs

- [x] PRD 05 §5 gets FR-STOR-4; README feature list if it lists settings.
