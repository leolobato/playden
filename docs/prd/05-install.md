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
  once.
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
  Order: stop the game if running, finish pending Cloud uploads or obtain explicit confirmation
  to discard unsynced local progress, delete game files, `cxbottle --delete` the bottle, clear install
  state. State clearly that local saves are removed; collections, rating, favorite and playtime are kept.
- **FR-UN-2 (future):** Optional local save retention and restore on reinstall are deferred by the
  user on 7 September 2026. v1 has no "Keep saves" option. Reinstalled games recover synchronized
  saves through Steam Cloud (§6); games without supported Cloud sync have no uninstall backup.
- **FR-UN-3 (v1):** Uninstall never touches a bottle not named `gn-<source>-<id>` for that game.
- **FR-UN-4 (v1):** Cloud saves through the source; see §6. Uninstall does not delete remote saves
  and cannot silently discard pending local uploads.

## 5. Storage

- **FR-STOR-1 (v1):** Games volume chosen at first run (02 FR-VOL-1); a game's location is recorded
  per install, so changing the volume affects new installs only.
- **FR-STOR-2 (v1):** An unmounted games volume shows its games as "Drive disconnected", not "Not
  installed"; Play is disabled with that reason.
- **FR-STOR-3 (v2):** Move an installed game to another volume; multiple game volumes.

## 6. Steam Cloud saves (v1)

Scope changed by the user on 7 September 2026: cloud save sync is required for v1.

- **FR-CLOUD-1 (v1):** For Steam Cloud-enabled games with a verified save mapping, synchronize
  remote saves into the owned game/bottle save locations before launch and changed local saves
  back to Steam Cloud after exit. Support the required UFS/remote-file behavior of the verified
  acceptance title; a metadata flag alone is not proof that its save sync works.
- **FR-CLOUD-2 (v1):** Show Up to date, Syncing, Pending upload, Conflict, Unavailable or Failed on
  the game page, with actionable errors and retry. Offer Play offline when authentication or
  connectivity prevents sync; preserve a durable pending upload for later retry.
- **FR-CLOUD-3 (v1):** Track local and remote revisions/checksums against the last successful sync.
  When both changed, ask which copy to use in a controller-accessible conflict screen showing
  timestamps and direction. Back up both copies before replacement. Never silently choose based
  only on the newest timestamp, overwrite an unresolved conflict, or upload while the game writes.
- **FR-CLOUD-4 (v1):** Transfers and sync state survive launcher restart. Remote writes are committed
  only after successful transfer and validation. Failed or interrupted transfers retain local
  saves and the last known remote revision. Crash/forced-exit saves require validation before upload.
- **FR-CLOUD-5 (v1):** Cloud identity, sync history and pending uploads are account scoped. Logging
  out does not delete local saves. Changing accounts must never silently upload another account’s
  local progress; require explicit resolution before attaching existing local saves to a new account.
- **FR-CLOUD-6 (v1):** Resolve save paths within verified owned locations; do not follow arbitrary
  remote paths or Wine links into unrelated files. Unknown mappings show an honest unsupported
  status and do not claim synchronization. Sync failures never delete local data. Uninstall
  accounts for pending uploads before deletion and explicitly describes loss of unsynced saves;
  reinstall downloads available Cloud saves before launch. This does not require local uninstall
  archives or a "Keep saves" feature in v1.

## 7. Native macOS games and official Steam integration (v2)

- **FR-MAC-1 (v2):** When a game offers a macOS build, expose it as an optional install/launch
  choice alongside Windows/CrossOver. Never force the macOS version or silently replace an existing
  Windows installation. Remember the player’s choice and allow it to change.
- **FR-MAC-2 (v2):** Discover installed games in the official Steam macOS client’s configured library
  folders, including libraries on other volumes. Merge by Steam app ID without duplicate library
  tiles, show their installed state and launch through the appropriate Steam/native path.
- **FR-MAC-3 (v2):** Distinguish Playden-managed installs from Steam-managed installs. Do not
  adopt, rewrite or remove the official client’s files as owned Playden storage. Disconnected
  Steam library volumes retain their installed identity and show their unavailable status.
- **FR-MAC-4 (v2):** Allow multiple installation/runtime choices per game in Catalog and the game
  page. Add a native/Steam runner behind the runner boundary; all native installation, discovery
  and launch UI remains outside v1.
