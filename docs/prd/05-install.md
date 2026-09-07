# PRD 05 — Sources, install and storage

Journey: **install a game**. From "Install" on a game page to "Play is available", and the reverse.
The pipeline talks only to the `Installer` and `GameRunner` protocols (01 §3).

## 1. Sources

- **FR-SRC-1 (v1):** `SteamSource`: owned games via `SteamCore` `Library`, metadata via PICS,
  `SteamInstaller` for depots. Windows depots always; english by default with the game's language
  configurable in v2 properties.
- **FR-SRC-2 (v2):** A second source, preferring GOG or itch.io (DRM-free, offline installers or the
  butler API) because they exercise the protocol without a second emulation layer.
- **FR-SRC-3 (later):** Epic (legendary-style protocol), `ManualSource` (add an exe already on disk
  into a new bottle), and non-store games from an existing bottle.
- **FR-SRC-4 (v1):** Adding a source in code requires no change to `Catalog`, `Installs`, `Runner` or
  any screen. This is verified by a test that runs the install pipeline against a `FakeSource`.

## 2. Install job

Stages, in order: **Estimate → Reserve space → Download → Create bottle → Post-install → Verify →
Installed.**

- **FR-INST-1 (v1):** Install shows the estimate (download size, disk size, free space on the games
  volume) and asks for confirmation once. Insufficient space blocks with a clear number.
- **FR-INST-2 (v1):** Progress is visible in three places with the same numbers: Downloads tab, game
  page, bottom-bar indicator. Stage name, percent, bytes, speed, ETA when downloading.
- **FR-INST-3 (v1):** Pause, resume and cancel per job. Cancel deletes partial files and any bottle
  created for it. Resume continues from complete chunks (`SteamCore` resume semantics).
- **FR-INST-4 (v1):** One job downloads at a time; others queue in order and can be reordered from the
  Downloads tab.
- **FR-INST-5 (v1):** Downloads pause automatically when a game is running; a Settings toggle allows
  downloading while playing.
- **FR-INST-6 (v1):** Jobs persist. After a launcher restart, in-progress jobs resume automatically
  and completed stages are not redone.
- **FR-INST-7 (v1):** Create bottle: `cxbottle --copy gn-template-<version>` into `gn-<source>-<id>`,
  then apply per-game bottle params from the `LaunchSpec` (DLL overrides via `cxstart --dll`, working
  dir). Bottle creation failure is a job failure with the `cxbottle` output attached (07 §2).
- **FR-INST-8 (v1):** Post-install for Steam: gbe_fork Mode A staging with `unlock_all=0` and the owned
  DLC list, synthetic offline identity, Steamless unpack for SteamStub exes, originals backed up
  once. Mirrors `GameNative-macos` FR-LAUNCH-2/3.
- **FR-INST-9 (v1):** Verify: file sizes against the manifest; a "Verify files" action is available
  on installed games and repairs missing or short files by re-downloading them.
- **FR-INST-10 (v2):** Game updates: detect a newer manifest, show "Update available", update on
  demand, keep the option to stay on the installed version.

## 3. Downloads tab

- **FR-DL-1 (v1):** List of jobs: active first, then queued, then recently finished or failed.
  Per-item progress, stage, pause/resume/cancel/retry via the context menu.
- **FR-DL-2 (v1):** Storage bar for the games volume: used by games, free, reserved by queued jobs.
- **FR-DL-3 (v1):** Failed jobs stay listed with the failing stage and reason until dismissed.

## 4. Uninstall

- **FR-UN-1 (v1):** Uninstall confirms with what is removed: game files size and the game's bottle.
  Order: stop the game if running, delete game files, `cxbottle --delete` the bottle, clear install
  state. Collections, rating, favorite and playtime are kept.
- **FR-UN-2 (v1):** Saves: gbe_fork stores saves inside the game's bottle, so uninstall would delete
  them. v1 offers "Keep saves" (default on), which moves the bottle's save directories into
  `Application Support/GameNative BigScreen/saves/<source>-<id>/` and restores them on reinstall.
- **FR-UN-3 (v1):** Uninstall never touches a bottle not named `gn-<source>-<id>` for that game.
- **FR-UN-4 (later):** Cloud saves through the source.

## 5. Storage

- **FR-STOR-1 (v1):** Games volume chosen at first run (02 FR-VOL-1); a game's location is recorded
  per install, so changing the volume affects new installs only.
- **FR-STOR-2 (v1):** An unmounted games volume shows its games as "Drive disconnected", not "Not
  installed"; Play is disabled with that reason.
- **FR-STOR-3 (v2):** Move an installed game to another volume; multiple game volumes.
