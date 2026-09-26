# PRD 08 — Stores, local games and platforms

Journey: **play games from more than one place, on more than one platform**. Playden has been a
Windows-on-CrossOver Steam launcher with store-shaped protocols. This file makes it a launcher for
several stores and two platforms. v1 adds:

- **This Mac**: native macOS games that are already installed on this Mac;
- **Steam macOS builds**: installing and running the native macOS version of a Steam game.

Windows games already on disk are imported in **v2** (§10). More stores (itch.io, GOG, Epic,
Amazon) are **v3** (§11). The v1 model is shaped so that neither changes it again.

Drafted 2026-09-26 (Leo + Claude). It changes 01 (architecture), 02 (first run), 04 (library) and
05 (install). Where this file and an older journey file disagree, this file wins for store and
platform behavior.

## Decisions (dated 2026-09-26)

1. **This Mac games are native macOS apps only in v1.** Playden launches an `.app` bundle directly.
   It does not use CrossOver, and it never changes or removes the app's files. Windows games that are
   already on disk ("import into a bottle") are **v2** (§10).
2. **Steam macOS builds are v1.** When a Steam game has a macOS build, the player can install it
   instead of the Windows build. This pulls 05 FR-MAC-1 into v1. Playden still downloads the
   depots itself and never runs the Steam client. Installing both builds side by side
   (05 FR-MAC-4) and discovering games installed by the official Steam client (05 FR-MAC-2/3) stay
   **v2**.
3. **This Mac games get in by manual add and watched folders.** The player can add one `.app`, or
   pick folders that Playden scans again on every library sync. Playden also suggests games it finds
   in the standard Applications folders, but it adds only the ones the player confirms.
4. **One merged library, not a tab per store.** The top tabs stay Home, Library, Downloads and
   Settings. Stores appear in these places:
   - as entries in the Library rail;
   - as a Store filter;
   - as a small badge on tiles and on the game page;
   - on a Stores page in Settings.

   This follows the design brief: "do not make the store the organizing principle; the user's
   library is."
5. **Store and platform are different things.**
   - *Store* is where the game comes from: Steam, This Mac, and later itch.io and others.
   - *Platform* is what the game runs as: Windows (through CrossOver) or macOS (native).

   A Steam game can have both platforms. Filters show both groups when a library has more than one
   value.
6. **Playden never owns This Mac game files.** "Remove from library" deletes only Playden's
   records for the game. The Uninstall flow, bottle removal and save retention apply only to
   installs that Playden made.
7. **The store's display name is "This Mac".** Its source ID is `local`.
8. **Removing a This Mac game keeps its history.** Playtime, sessions and edits stay in the
   database. Adding the same app again restores them (FR-LOCAL-14).
9. **Warn about Steam-dependent Mac apps.** If a This Mac app contains `libsteam_api.dylib`, the
   game page warns that it may need the Steam client (FR-LOCAL-17).
10. **Steam Cloud sync for macOS builds waits for v2** (FR-SMAC-9). A macOS build has no Steam
    Cloud sync in v1.
11. ***Prefer macOS versions* is on by default for every game**, including games already rated
    Works on Windows (FR-SMAC-2). The preselection is only a default: the player's last choice for
    a game still wins.
12. **Playden builds its own macOS gbe_fork.** Upstream gbe_fork ships only Windows and Linux builds
    (feature request Detanup01/gbe_fork#189 is open, with no work on it). Playden keeps a
    reproducible build: `scripts/build-gbe-macos.sh` builds a universal (arm64 + x86_64)
    `libsteam_api.dylib` from a pinned upstream commit, with patches kept in `Native/GBEMac/`.
    The output and its SHA-256 are recorded in the `steampipe` resource `PROVENANCE.md`, as for the
    Windows DLLs. The spike in §12 step 0 still has to prove that the build reaches gameplay.
13. **Release tiers:** This Mac and Steam macOS builds are v1, Windows import is v2, and other
    download stores are v3. This replaces 01 AR-PROTO-2 and 05 FR-SRC-2/FR-SRC-3, which put GOG or
    itch.io in v2 and Epic in later.

## 1. What changes, in one picture

```
                 ┌────────────── SourceRegistry ───────────────┐
                 │  SteamSource        LocalSource  (v3 stores)  │
                 └──────┬───────────────────┬────────────┬───────┘
   capabilities:        │ account           │ no account │ account
                        │ downloads         │ external   │ downloads
                        │ cloud saves       │ files      │
                        │ Windows + macOS   │ macOS      │
                        ▼                   ▼            ▼
   InstallationRecord { ownership: .playden | .external,
                        runtime:   .crossOver(bottle) | .native }
                        │
                 RunnerRegistry ─┬─ CrossOverRunner   (Steam Windows builds)
                                 └─ NativeRunner      (Steam macOS builds, This Mac apps)
```

| | Ownership | Runtime | Installed by |
|---|---|---|---|
| Steam, Windows build | `.playden` | `.crossOver` | `InstallQueue` (today) |
| Steam, macOS build | `.playden` | `.native` | `InstallQueue` (new platform branch) |
| This Mac app | `.external` | `.native` | nobody. Found by `LocalSource` |
| v2 Windows import | either | `.crossOver` | import job or in place |

Today the app layer builds one `SteamSource` (`App/PlaydenApp.swift:40`), and `LibraryModel` stores
it as `source: (any GameSource)?`. `InstallQueue` and `SessionService` already accept
`sources: [any GameSource]`. The current code makes four assumptions, and this spec removes all four:

- Every `InstallationRecord` has a Playden-owned folder (`GameLocation` + ownership token).
- Every `InstallationRecord` has a CrossOver bottle (`bottleID`, `templateVersion`).
- `RunningGame` always embeds a `GameBottle`.
- Steam install resolution accepts only Windows depots and `.exe` launch entries
  (`SteamInstallPlan.swift:66`, `:79`, `:106`).

## 2. Architecture changes

### 2.1 Source registry and capabilities

- **AR-SRC-1 (v1):** Add `SourceRegistry` in `Domain`. It holds the configured `[any GameSource]` by
  `id`. It is the only way these components find a source: the app, `InstallQueue`,
  `SessionService`, cloud sync and library sync. `LibraryModel.source` becomes
  `LibraryModel.sources: SourceRegistry`.
- **AR-SRC-2 (v1):** `GameSource` declares what it can do. The UI branches on these values, never on
  `id == "steam"`:

  ```swift
  public struct SourceCapabilities: Sendable {
      var account: AccountKind          // .none, .qrAndPassword (Steam), .oauth (v3 stores)
      var acquisition: Acquisition      // .download (Playden installs), .external (already on disk)
      var cloudSaves: Bool              // Steam only today
      var storePage: StorePagePolicy?   // URL builder + allowed hosts; nil hides "Store page"
      var libraryRefresh: RefreshKind   // .remote (every 6 h + launch), .scan (launch + on demand)
  }
  ```

- **AR-SRC-3 (v1):** A source with `account == .none` returns `NoSourceAuth`: it has no identity,
  its sign-in fails, and the UI shows no sign-in, no sign-out and no "Signed in as" row.
- **AR-SRC-4 (v1):** `installer(for:)` is used only when `acquisition == .download`. External sources
  instead provide `func locate(_ game: SourceGameRecord) async throws -> ExternalInstall`. It returns
  the app's current URL, `missing` or `volumeUnavailable`.
- **AR-SRC-5 (v1):** Move the Steam-only helpers behind the source:
  - The store page URL and host allow list (`App/StorePage.swift:9`, `:114`, `:146`) move into
    `storePage`.
  - The header-art fallback (`App/ArtworkCache.swift:48`) moves into a new source method,
    `artworkFallbacks(for:) -> [URL]`.
  - Cloud sync wiring (`App/LibraryModel.swift:297`) becomes a lookup keyed by source:
    `cloudServices[sourceID]`. It is built only for sources that have `cloudSaves`.
- **AR-SRC-6 (v1):** `SourceFailure.errorDescription` and every user-visible "Steam" string in the
  app are either generic ("the store") or formatted with `source.displayName`. Examples:
  - the empty states in `LibraryViews.swift:227-258`;
  - the account row in `SupportViews.swift:21`;
  - `LibraryEditing.swift:39-41` and `:203`;
  - the uninstall copy in `SupportViews.swift:271`.

  Steam-only flows (QR sign-in, Steam Guard) may keep saying Steam.
- **AR-SRC-7 (v1):** Source identifiers are constants in `Domain` (`SourceID.steam`,
  `SourceID.local`, later `SourceID.itch`), not string literals in the app.
- **AR-SRC-8 (v1):** Add `enum GamePlatform: String, Codable { case windows, macOS }`.
  `SourceGameRecord` gains `platforms: [GamePlatform]`, the builds the source offers. The default
  for legacy records is `[.windows]`.

### 2.2 Installations: ownership, runtime and platform

- **AR-INST-1 (v1):** `InstallationRecord` records who owns the files and how the game runs. The
  fields are added to the existing record, so nothing about the stored format changes for owned
  installs:

  ```swift
  var runtime: RuntimeBinding?     // .crossOver or .native; nil on legacy records = .crossOver
  var external: ExternalLocation?  // set for apps found on disk; the files are the user's
  struct ExternalLocation: Codable { var bookmark: Data?; var lastKnownPath: URL
                                     var bundleIdentifier: String?; var executableName: String? }
  ```

  For an external install, `location` only mirrors the app's parent folder, and `bottleID` is
  empty. The platform follows from the runtime: `.crossOver` is Windows and `.native` is macOS.
- **AR-INST-2 (v1):** Records are JSON payload blobs (`installations` table), and the new fields are
  optional. A legacy record therefore decodes as a Playden-owned CrossOver install, with no
  migration code. A test decodes a record without the new keys.
- **AR-INST-3 (v1):** An `InstallationLocator` replaces `InstallStorage.directory(_:gameID:owner:)`
  and resolves both ownership cases:
  - Owned locations keep today's ownership-marker checks.
  - External locations resolve the bookmark. They report `.volumeUnavailable`, which maps to the
    existing `driveDisconnected` status, or `.missing`, a new status (§5.4).
- **AR-INST-4 (v1):** The removal code rejects `.external` records at the type level. It takes the
  owned case only, so it cannot be called with an external location. This covers
  `InstallStorage.remove`, `OwnedDirectoryRemoval`, bottle removal and save retention in
  `UninstallModel`.
- **AR-INST-5 (v1):** `InstallStatus` gains `missing`: the record exists, but the app is no longer at
  its location, and the bookmark cannot find it.
- **AR-INST-6 (v1):** `Installer.resolve()` becomes `resolve(platform: GamePlatform)`, and
  `InstallPlan` gains `platform`. `JobRecord.bottle` is nil for a native plan. For native plans,
  `InstallQueue` skips the `createBottle` and `prerequisites` stages and commits a `.native`
  runtime. The other stages stay the same: reserve, download, verify, stage, validate and commit.
  Pause, resume, reorder and resume after restart work unchanged.

### 2.3 Runners

- **AR-RUN-1 (v1):** `RunningGame` gains an optional `native: NativeRun` (the bundle URL and
  bundle identifier). For a native run, `bottle` carries only the game and ownership identity.
  Persisted `RunSnapshot`s (in `sessions`) without the key decode as CrossOver runs, so crash
  recovery still works across the upgrade.
- **AR-RUN-2 (v1):** `SessionService` takes an optional `nativeRunner` next to its CrossOver
  `runner`. It picks the runner from the installation's `RuntimeBinding`, and it picks it from
  `RunningGame.native` during recovery. `NativeRunner` conforms to the existing `GameRunner`
  protocol, so `CrossOverRunner` does not change.
- **AR-RUN-3 (v1):** `NativeRunner` (in `Runner`) implements `GameRunner`:
  - `prepare` / `completePreparation`: no-op, returns `false`.
  - `launch`: `NSWorkspace.openApplication(at:configuration:)` with `activates = true` and
    `createsNewApplicationInstance = false`, plus the arguments and environment from `LaunchSpec`.
    It records the `ProcessIdentity` of the returned `NSRunningApplication`.
  - `observe`: the process set is every process owned by the user whose executable path is inside
    the bundle. This is the bottle-prefix scan in `RuntimeProcessInspector.inspect(bottle:)`,
    generalized to `inspect(root:)`, so launcher stubs that start the real game are followed. Windows
    come from `CGWindowListCopyWindowInfo` by owner PID, which already works for native apps
    (`GameActivation.swift`).
  - `terminate`: `NSRunningApplication.terminate()`, then `forceTerminate()` after the existing grace
    period, applied to every tracked PID.
  - `recover`: re-attach by `ProcessIdentity` (PID + start time), as today.
- **AR-RUN-4 (v1):** In `SessionService.launchTracked`, the bottle-only steps run only for a
  `.crossOver` runtime: `runner.prepare`, prerequisites and `postInstall` restaging. Two steps run
  for any runtime that has them:
  - source runtime options (`applyRuntimeOptions`);
  - the cloud mapping, when there is a `plan` and the source has `cloudSaves`.

  A This Mac launch goes directly from "locate" to "launch". Playtime, outcomes, the exit overlay
  (06) and download pause during play work unchanged.
- **AR-RUN-5 (v1):** If the app is already running when the player presses Play, Playden adopts that
  instance as the session. It activates the app and tracks it, and it does not start a second copy.
  The game page shows "Return to game", as it does for a running CrossOver game.
- **AR-RUN-6 (v1):** Native launches do not capture stdout. The diagnostic log records lifecycle
  events: located, launched, window seen, exited with a code. It suggests Console.app for app output.

### 2.4 Library sync

- **AR-SYNC-1 (v1):** `LibrarySyncCoordinator.refresh(source:)` already works per source, and
  `source_sync` is keyed by source. The app layer calls it for each registered source on that
  source's schedule:
  - remote sources: on launch, every 6 h and from Settings (04 FR-LIB-5);
  - `LocalSource`: on launch, when the app becomes active, after an add or remove, and from
    Settings.
- **AR-SYNC-2 (v1):** A failure in one source never blocks another source's refresh or hides that
  source's games. Sync errors are recorded per source (`syncErrors[sourceID]`) and shown on that
  source's Settings row.
- **AR-SYNC-3 (v1):** Signing out of Steam clears the Steam catalog only. That is the existing
  behavior of `replaceSourceCatalog(source:)`. Resetting app data also clears the This Mac store
  (§3.1).

## 3. This Mac source

### 3.1 Storage

- **FR-LOCAL-1 (v1):** `LocalSource` keeps its own store, `local-games.json` in the app's support
  folder, written atomically. It cannot rely on the catalog, because `replaceSourceCatalog` replaces
  a source's rows on each sync, and the `Sources` module does not depend on the database.
  `LibrarySyncCoordinator` writes the scanned games and their installation records in one catalog
  transaction (`CatalogStore.replaceExternalCatalog`).

  | Collection | Fields |
  |---|---|
  | `entries` | `gameID`, `bookmark`, `lastKnownPath`, `bundleIdentifier`, `executableName`, `origin` (`manual` / `folder(id)` / `suggested`), `addedAt` |
  | `folders` | `id`, `bookmark`, `lastKnownPath`, `depth` (default 2) |
  | `removed` | `gameID`, `lastKnownPath`, `bundleIdentifier`, `executableName`, `removedAt` (games the player removed; §3.5) |

- **FR-LOCAL-2 (v1):** `ownedGames()` returns one `SourceGameRecord` for each entry that still
  exists, plus each new app found in a watched folder that is not in `removed`. It creates the
  matching `InstallationRecord` (`.external` + `.native`) in the same catalog transaction. A This
  Mac game is therefore always installed, disconnected or missing, and never "not installed".

### 3.2 Identity

- **FR-LOCAL-3 (v1):** `GameID(source: "local", value: <UUID>)`. The UUID is created when the game
  is added and is never derived from the path. Playtime, favorites, collections and ratings therefore
  survive moves and renames.
- **FR-LOCAL-4 (v1):** When Playden finds an app, it compares it with the existing and removed
  entries. The rules are tried in this order:
  1. the bookmark resolves to the app;
  2. the path is the same;
  3. the `bundleIdentifier` **and** the executable name are both the same.

  The bundle identifier alone is not enough, because many engine builds ship a default one (for
  example `com.unity3d.*`).

### 3.3 Discovery

- **FR-LOCAL-5 (v1):** **Add a game.** Settings → Stores → This Mac → *Add a game* opens a picker
  that works with the controller:
  - It lists candidate apps (FR-LOCAL-7), each with an icon, a name and a path.
  - A *Browse…* item opens `NSOpenPanel`, filtered to `.app`, for keyboard and mouse users.
- **FR-LOCAL-6 (v1):** **Watched folders.** Settings → Stores → This Mac → *Folders* lists each
  folder with its game count, and offers *Add folder* (`NSOpenPanel`, directories only) and
  *Remove*.
  - Removing a folder asks whether to also remove its games from the library. By default, the games
    stay as manual entries.
  - A scan checks two levels deep, which covers `Steam/steamapps/common/<Game>/<Game>.app`.
  - A scan skips `.app` bundles that are nested inside another bundle.
- **FR-LOCAL-7 (v1):** **Suggestions.** The picker also lists apps in `/Applications`,
  `~/Applications` and `~/Games` that look like games:
  - apps whose `LSApplicationCategoryType` is `public.app-category.games` or a
    `public.app-category.*-games` subcategory;
  - apps that embed a known game-engine framework (Unity, Unreal, Godot, GameMaker).

  Apps already in the library are shown as added. Suggestions are never added without confirmation.
- **FR-LOCAL-8 (v2):** When the Steam for Mac and GOG Galaxy library folders exist, suggest them as
  watched folders. Match their apps to Steam app IDs through `steam_appid.txt` or
  `appmanifest_*.acf` (links to 05 FR-MAC-2).

### 3.4 Metadata and artwork

- **FR-LOCAL-9 (v1):** Metadata comes from the app bundle:
  - The title is `CFBundleDisplayName`, then `CFBundleName`, then the bundle file name.
  - The summary and genres are empty, and `controllerSupport` is `.unknown`.
  - `importedPlaytimeSeconds` is `0`, `sourceAcquiredAt` is `addedAt`, and `platforms` is
    `[.macOS]`.
- **FR-LOCAL-10 (v1):** The player can rename a This Mac game from the context menu and the game
  page. The new name is a title override in `GameEdits`, and it survives rescans.
- **FR-LOCAL-11 (v1):** Until real art exists, the tile shows the generated placeholder
  (04 FR-ART-1) with the app icon (`NSWorkspace.icon(forFile:)`) centered on it. The hero uses a
  blurred, enlarged icon over the ambient backdrop. `ArtworkLoader` gains a local-icon provider, so
  icons are cached like remote art.
- **FR-LOCAL-12 (v2):** SteamGridDB lookup by title for cover, hero and logo (04 FR-ART-2), with
  "Choose cover" to pick another result or a local image file.

### 3.5 Game-page actions for This Mac games

- **FR-LOCAL-13 (v1):** The primary action is Play or Return to game. There is never Install, a
  download size, Verify files or Uninstall.
- **FR-LOCAL-14 (v1):** The secondary actions are:
  - Favorite, Add to collection, Hide, Rename and Set compatibility;
  - View logs;
  - *Show in Finder* (hidden in controller-only mode);
  - *Remove from library*.

  **Remove from library** deletes the `entries` item and the installation record, and adds a
  `removed` item. Watched folders then skip the app. The game's rows in `game_edits` and
  `sessions` are kept.

  - The confirmation says: "Removes <Title> from Playden. The app stays on your Mac, and your
    playtime is kept if you add it again."
  - If the player adds the app again (from the picker, Browse or a folder they add later) and it
    matches a removed entry by FR-LOCAL-4, Playden reuses the old `GameID`. Playtime, favorites,
    collections, the rating and the title override come back.
  - The picker shows removed apps as normal candidates.
  - Reset app data deletes everything, including removed entries.
- **FR-LOCAL-15 (v1):** Game settings (the CrossOver runtime profile sheet, `GameSettingsSheetView`)
  are hidden for This Mac games. **(v2):** native launch arguments and a "Make game display
  primary" toggle that reuses `TemporaryPrimaryDisplay`.
- **FR-LOCAL-16 (v1):** The cloud save UI (`CloudViews`) never shows for This Mac games. The game
  page's metadata strip shows "Saves: managed by the game".
- **FR-LOCAL-17 (v1):** **Steam dependency warning.** A scan checks whether the bundle contains
  `libsteam_api.dylib` (anywhere under `Contents/`) and stores the result with the entry. If it
  does, the game page shows a notice:

  > "This game uses Steam. It may close or ask for the Steam app when started from Playden."

  If the player's Steam library in Playden has a game with the same title, the notice also offers
  *Show the Steam version*. From there the player can install the Steam macOS build, which Playden
  can run without the Steam client (§4). The notice never blocks Play.

## 4. Steam macOS builds

- **FR-SMAC-1 (v1):** **Know which platforms a game has.** `SteamSource.parseMetadata` reads
  `platforms { windows, mac }` from the `appdetails` response it already fetches, and fills
  `SourceGameRecord.platforms`. At resolve time, PICS depot and launch `oslist` values are
  authoritative. A game whose store data says "mac" but that has no usable macOS depot or launch
  entry falls back to Windows only, and the install offer says why.
- **FR-SMAC-2 (v1):** **Install offer with a platform choice.** When a game offers both platforms,
  the install offer (`installOffer` panel) shows two choices:
  - **macOS version**, with its download and disk size;
  - **Windows version**, with its sizes and a "Runs with CrossOver" note.

  Rules for the choice:
  - A Settings toggle, *Prefer macOS versions* (default on), sets the preselected choice. It
    applies to every game, including games rated Works on Windows (decision 11).
  - The player's last choice for a game is remembered in `GameEdits.preferredPlatform`.
  - A game with only one platform shows no choice.
- **FR-SMAC-3 (v1):** **One installed build per game.** The game page offers *Switch to the Windows
  version* or *Switch to the macOS version* when the other platform exists.
  - The confirmation states the consequence: the installed build is removed first, then the other
    one is queued.
  - Save retention and cloud rules for the removal are the same as for uninstall (05 §4).
  - It never happens automatically (05 FR-MAC-1).
  - Keeping both builds installed at once is **v2** (05 FR-MAC-4). It needs the
    `installations (source, game)` unique key to include the platform.
- **FR-SMAC-4 (v1):** **Resolve.** `SteamInstallPlan.selectedDepots` and `launchOptions` take the
  platform.
  - For macOS, depots are selected when their `oslist` contains `macos`, or when the `oslist` is
    empty (shared content), with the same language, DLC and ownership rules as today.
  - Launch entries are selected when their `config.oslist` contains `macos`.
  - The executable is normalized to the enclosing `.app` bundle (`Game.app` or
    `Game.app/Contents/MacOS/Game`), which must have an `Info.plist`.
  - Arguments use POSIX shell-word parsing, not `WindowsArguments`.
  - `osarch` and the Mach-O slices decide the architecture. arm64 or universal builds run natively.
    A build with x86_64 only needs Rosetta: the offer says so, and Play checks for Rosetta and
    explains how to install it if it is missing.
- **FR-SMAC-5 (v1):** **File modes.** Downloads today are written as `0o600`
  (`DownloadWorkspace.swift:51`), and the manifest's executable flag (`DepotManifest.File.isExecutable`,
  flag 32) is ignored.
  - Files with that flag become `0o755`, and so do Mach-O files under `Contents/MacOS`, because some
    depots omit the flag.
  - Symlinks are already written safely (`createSymlink`). Frameworks need them.
  - Verification also checks modes, so Verify files can repair a lost executable bit.
- **FR-SMAC-6 (v1):** **Steam API without the Steam client.** This is the macOS equivalent of the
  gbe_fork DLL staging (`Prepare.swift`, `GBEAssets`):
  - Playden bundles a universal (arm64 + x86_64) gbe_fork `libsteam_api.dylib`, with pinned hashes
    as for the DLLs.
  - It replaces each `libsteam_api.dylib` in the bundle (`Contents/Frameworks`, Unity's
    `Contents/Plugins`, and so on). The original is kept as a `FileMutation` with a `.orig` backup,
    so verify and repair work as they do for Windows.
  - It writes `steam_settings` next to each replaced library, using the same account, app ID,
    interface and DLC data as the Windows path.
  - Steamless does not apply, because SteamStub is Windows-only.
  - **Gate:** gbe_fork has no official macOS release. A spike must first prove a working build
    (§12 step 0). Until it passes, the macOS choice is offered only for depots with no
    `libsteam_api.dylib`. Other games show "The macOS version needs the Steam app. Install the
    Windows version instead." with the macOS choice disabled.
- **FR-SMAC-7 (v1):** **Code signature.** Replacing a library breaks the bundle's signature, and a
  hardened-runtime executable refuses to load a library with a different signature. After
  staging, Playden therefore:
  1. re-signs the modified bundle ad hoc (`codesign --force --deep --sign -`), through the existing
     `CommandExecutor`;
  2. removes `com.apple.quarantine` if it is present;
  3. validates the result with `codesign --verify`.

  The staging record keeps a version number, so a later recipe change triggers restaging, as it
  does for Windows.
- **FR-SMAC-8 (v1):** **Launch.** `NativeRunner` runs the bundle from the owned install directory,
  which `InstallationLocator` resolves. Steam emulator options (for example the overlay setting
  written by `applyRuntimeOptions`) still apply. The CrossOver runtime profile sheet is hidden, and
  a *Steam emulator* section stays.
- **FR-SMAC-9 (v1):** **Cloud saves are Windows only for now.** macOS save rules
  (`ufs.savefiles` with `platforms: MacOS`, and roots such as `MacAppSupport` and `MacHome`) point
  outside the game folder. Today the save store resolves only the `game` and `bottle` roots.
  - In v1, a macOS build has no Steam Cloud sync (decision 10). The install offer and the game
    page say "Steam Cloud saves: Windows version only for now".
  - **(v2):** a `SaveRoot.home` that resolves only an exact declared list of `~/Library` and
    `~/Documents` subfolders, and never the home folder itself. It reuses `CloudSyncService`
    unchanged.
- **FR-SMAC-10 (v1):** **Uninstall** removes the owned install folder. There is no bottle. macOS
  saves live in the player's Library folder, not in the game folder, so uninstall does not touch
  them, and the confirmation says so.
- **FR-SMAC-11 (v1):** **Compatibility rating is per game** in v1. The game page labels it with the
  installed platform ("Works · macOS version"). **(v2):** a separate rating for each platform.
- **FR-SMAC-12 (v1):** `Playden --diagnose-install` (`PlaydenApp.swift:76`) gains
  `--platform macos|windows`.

## 5. Library UI (changes to 04)

### 5.1 Rail

- **FR-STORE-1 (v1):** The Library rail is, in order:
  1. Installed, All, Favorites, Hidden;
  2. a **Stores** section label, then one entry for each source that has at least one game;
  3. the collections.

  The Stores section is hidden when only one source has games, so a Steam-only player sees no
  change. `LibraryScope` gains `.store(String)`, which is persisted like the other scopes.
- **FR-STORE-2 (v1):** A store entry shows the store icon and name. Selecting it combines with
  Installed and the other filters: store scope AND refinements.

### 5.2 Filters (Options)

- **FR-STORE-3 (v1):** The existing *Source* group (`LibraryFilters.swift:52`) is renamed *Store*.
  Its chips use `displayName`, not the capitalized id. The group is hidden while a `.store` scope is
  selected, because it would be redundant.
- **FR-STORE-4 (v1):** A new *Platform* group (Any, Windows, macOS) appears when the visible games
  have more than one platform. The filter matches:
  - for an installed game: the platform of its runtime (`.crossOver` → Windows, `.native` → macOS);
  - for a game that is not installed: any platform in `SourceGameRecord.platforms`. "macOS" then
    also answers "which of my Steam games have a Mac version?"

  `LibraryRefinements` gains `platform: GamePlatform?`.
- **FR-STORE-5 (v1):** A *Missing* value joins the Installed filter group when at least one game is
  missing.

### 5.3 Tiles and game page

- **FR-STORE-6 (v1):** When more than one source has games, each tile shows a small store glyph in
  the top-left corner. The glyph is less prominent than the state badges (04 FR-LIB-4) and never
  covers the download glyph. With one store, no glyph is shown.
- **FR-STORE-7 (v1):** The game page's metadata strip shows two new items:
  - *Store*: the display name. It replaces `game.id.source.capitalized` at `LibraryViews.swift:329`.
  - *Runs as*: "Windows · CrossOver" or "macOS". For a game that is not installed and has both
    platforms, it shows "macOS or Windows".
- **FR-STORE-8 (v1):** Search matches titles across all stores. Duplicate titles across stores stay
  separate tiles, and the store glyph tells them apart.
- **FR-STORE-9 (v2):** Link duplicates. When a This Mac app matches a Steam app ID (FR-LOCAL-8),
  show one tile with two choices.

### 5.4 States

- **FR-STORE-10 (v1):** *Missing*: the tile is dimmed and has a warning badge. The game page says
  "<Title> isn't where Playden last saw it." It offers two actions:
  - **Locate…**: opens the picker or `NSOpenPanel`, bookmarks the app again and keeps the same
    `GameID`;
  - **Remove from library**.
- **FR-STORE-11 (v1):** *Drive disconnected* reuses the existing state and copy. Play waits for the
  volume, as for Steam installs.

### 5.5 Home

- **FR-STORE-12 (v1):** Home rows do not depend on the store:
  - Continue Playing, Favorites and pinned collections include This Mac games.
  - Recently Installed includes them too, using `addedAt`.
  - Downloading Now never includes them.

### 5.6 Empty states

- **FR-STORE-13 (v1):** When there are no games and no connected stores, Home and Library say "Add
  your games" and offer two actions: *Sign in to Steam* and *Add games on this Mac*. The copy no
  longer assumes Steam (`LibraryViews.swift:227-258`).

## 6. Settings

- **FR-SET-STORE-1 (v1):** Settings gains a **Stores** page. It replaces the single Steam account
  row (`SupportViews.swift:21`) and has one row per source:
  - **Steam:** "Signed in as X" or "Sign in", Sign out, Refresh library, the last sync time or error,
    and the *Prefer macOS versions* toggle (FR-SMAC-2).
  - **This Mac:** "N games · M folders", Add a game, Folders, Rescan now, and the last scan time.
  - **v3 stores:** Sign in or out, Refresh, and the last sync time or error, as for Steam.
- **FR-SET-STORE-2 (v1):** CrossOver (runtime) settings stay where they are. The page explains that
  CrossOver is needed only for Windows games.

## 7. First run (changes to 02)

- **FR-FIRST-STORE-1 (v1):** The account step becomes **Add your games**, with three choices:
  - *Sign in to Steam* (the existing QR and password flows);
  - *Add games on this Mac* (the FR-LOCAL-5 picker, filled with suggestions);
  - *Skip for now*.

  After Steam or This Mac, the player comes back to this step, so they can do both.
- **FR-FIRST-STORE-2 (v1):** The **games drive** step is required only when a download store is
  connected. The **CrossOver runtime** step can be skipped, with the copy "Needed for Windows games.
  You can set it up later in Settings."
  - A player who uses only This Mac or Steam macOS builds finishes setup without CrossOver.
  - Installing a Windows build without CrossOver opens the runtime setup first
    (`SetupScreen.runtime`).

## 8. Downloads, uninstall and jobs

- **FR-JOB-STORE-1 (v1):** This Mac games never create jobs. `InstallQueue` rejects any request for
  a source with `acquisition == .external`, and a test covers this rule.
- **FR-JOB-STORE-2 (v1):** Steam macOS installs appear in Downloads like Windows installs. Their row
  shows "macOS version".
- **FR-JOB-STORE-3 (v1):** Reset app data (`ResetModel`) also deletes `local-games.json`. It never
  touches This Mac app files.

## 9. Tests and verification

- **Domain/Catalog:**
  - legacy `InstallationRecord`, `RunSnapshot` and `SourceGameRecord` decoding;
  - the `local-games.json` store;
  - identity matching (FR-LOCAL-4), including the shared Unity bundle ID case;
  - remove followed by re-add, which restores playtime and edits.
- **Sources, LocalSource:** scans of fixture folders in a temp directory, built from minimal `.app`
  bundles (`Info.plist` + executable). Cover:
  - scan depth and nested bundles;
  - categories;
  - moves, renames and missing apps;
  - `libsteam_api.dylib` detection.
- **Sources, Steam macOS:**
  - `selectedDepots` and `launchOptions` for each platform, from recorded PICS fixtures (Windows
    only, macOS only, both, shared depots);
  - bundle normalization;
  - POSIX argument parsing;
  - `platforms` parsing from `appdetails`.
- **SteamKit:**
  - executable-bit and symlink handling in `DownloadWorkspace`;
  - macOS staging: dylib replacement, `.orig` backup, `steam_settings` and re-signing, against a
    fixture bundle.
- **Runner:**
  - `NativeRunner` launching a tiny fixture app that opens a window and exits with a known code;
  - adopting a running instance;
  - forced termination;
  - recovery by `ProcessIdentity`.
- **Installs:** a native plan skips the bottle stages and commits `.native`; the platform switch
  removes the installed build, then queues the other one.
- **Sessions:** a native launch skips the bottle steps but applies source options; playtime and the
  outcome are recorded; download pause still applies.
- **App:**
  - Store, Platform and Missing filters;
  - the rail Stores section appears only with more than one source;
  - install offer platform choice and preference;
  - Remove from library copy;
  - first-run skip rules.
- **Screenshot captures** (`PlaydenApp.swift:614` list), new entries:
  - `library-stores`, `library-filters-platform`;
  - `game-local`, `game-local-missing`, `game-local-steam-warning`;
  - `install-offer-platform`, `game-switch-platform`;
  - `settings-stores`, `settings-local-folders`;
  - `local-picker`, `setup-add-games`.

  Add a few This Mac games with icons and a two-platform Steam game to the preview catalog.
- **Manual:**
  - Add a native game from `/Applications` and one from an external drive. Play it with the
    controller and quit from the exit overlay. Unplug the drive. Move the app and rescan.
  - Install the macOS build of a known Steam game. Candidates to verify: A Short Hike and TUNIC,
    which both ship macOS builds. Play it, quit it, verify files, switch to Windows, and switch back.

## 10. v2: import Windows games into bottles

Planned here so that the v1 model does not block it. Nothing below is built in v1.

- **FR-IMPORT-1 (v2):** *Add a Windows game* on the This Mac page: pick a folder, then pick the
  executable from a list of the `.exe` files in that folder that works with the controller. Icons
  come from `WindowsExecutableIcon`. The list ranks likely game executables first, and puts
  `unins*`, `setup*`, redistributables and crash handlers last.
- **FR-IMPORT-2 (v2):** There are two import modes:
  - **Play in place:** the files stay external (`.external` ownership) and are mapped into the
    bottle as a drive or through `Z:`.
  - **Copy to Playden storage:** the files become Playden-owned on the games drive (`.playden`).

  Both modes create a Playden-owned bottle (`.crossOver`) from the template.
- **FR-IMPORT-3 (v2):** Copy mode runs as a job in the Downloads queue: a new `JobKind.importCopy`
  with the stages `reserve`, `copy`, `createBottle`, `validate` and `commit`. It reuses pause,
  resume, retry and resume after restart.
- **FR-IMPORT-4 (v2):** Game settings (runtime profiles), the exit overlay, display helpers and
  playtime work as they do for Steam.
  - Removing an in-place import deletes the bottle, but never the external files.
  - Removing a copied import behaves like uninstall.
- **FR-IMPORT-5 (v2):** Installer executables (such as GOG offline `setup_*.exe`) run inside the new
  bottle in a guided flow. After that, the player picks the installed executable. This needs a
  writable `C:` install location in the bottle. It is separate from FR-IMPORT-1 because it takes
  longer and fails more often.
- **FR-IMPORT-6 (v2):** The Platform filter shows imported games as Windows, and the Store filter
  shows them as This Mac.

## 11. v3: more stores

Each v3 store is a `download` source that installs into Playden-owned storage, like Steam. The
decision from 2026-09-07 still applies: Playden downloads the files itself and never shows a store's
own client. A store that can run a game only while its client is running is **later**, not v3.

What each v3 store needs beyond v1:

- **Platform choice: already done.** Steam macOS builds (§4) deliver the install-time platform
  choice, owned native installs and `NativeRunner`. v3 stores reuse them.
- **Generic download jobs.** `InstallQueue` runs Steam depots today. The v3 stores need HTTP
  downloads with resume, and unpacking for zip, dmg, tar and GOG/Inno Setup installers
  (`innoextract`-style unpacking, so that no installer has to run in a bottle).
- **Sign-in on a TV.** Where a store supports it, use a device-code or QR flow. Otherwise, show a
  short code on the TV and complete the sign-in in a browser on the phone. Do not make the player
  type a password on the on-screen keyboard.

| Store | Tag | Sign-in | Library and downloads | Launch notes | Effort |
|---|---|---|---|---|---|
| **itch.io** | v3 | OAuth or API key | Official API: owned keys and uploads for each platform | DRM-free. No staging. Many macOS builds | Low. Good first v3 store |
| **GOG** | v3 | OAuth (the Galaxy client ID that Heroic and lgogdownloader use) | Unofficial but stable API: owned games, offline installers and Galaxy depot manifests | DRM-free. Windows and macOS builds. Galaxy cloud saves can reuse the §6 cloud design in 05 | Medium |
| **Epic Games Store** | v3 | Web login that returns an auth code (legendary's protocol) | Manifests and CDN chunks (legendary's protocol) | Games that use Epic Online Services need launch tokens passed as arguments, so `LaunchSpec` must be built fresh before each launch, and offline play is limited. Epic cloud saves are optional. Anti-cheat titles stay out of scope | High |
| **Amazon Prime Gaming** | v3 | Amazon device sign-in (nile's protocol) | Manifests and downloads (nile's protocol) | Windows only. Some games need the Amazon Games client's SDK DLL: needs research | Medium |
| **Humble** | later | Session cookie | Library and DRM-free downloads (Humble Trove and bundle downloads) | Most Humble purchases are Steam keys and are already in the Steam library | Low value |
| **EA app, Ubisoft Connect, Battle.net** | later | Their own client | Their own client | They need their client running in the bottle. That conflicts with "no store client" and needs a separate "client in a bottle" runtime mode | High |
| **Emulators and ROM folders** | later | None | A This Mac–style scan (§3) of ROM folders | Needs an emulator runner (for example RetroArch) and per-system artwork | Separate project |

- **FR-V3-1 (v3):** Generic HTTP download jobs and unpacking, built once and before the first v3
  store.
- **FR-V3-2 (v3):** itch.io source.
- **FR-V3-3 (v3):** GOG source, including Galaxy cloud saves where the game declares them.
- **FR-V3-4 (v3):** Epic source, including EOS launch tokens. When a token cannot be fetched
  offline, disable Play and say why.
- **FR-V3-5 (v3):** Amazon source, after a research spike on its client SDK dependency.
- **FR-V3-6 (later):** Humble, launcher-bound stores, and emulators and ROM folders.
- **FR-V3-7 (v3):** A game owned on several stores shows as one tile with a store choice. This
  extends FR-STORE-9. It needs a cross-store identity match: the same title, plus a shared ID where
  one exists (IGDB or SteamGridDB).

## 12. Delivery order

Each step ships on its own and keeps Steam Windows installs working.

0. **Spike (in parallel with step 1):** a universal gbe_fork `libsteam_api.dylib` (decision 12).
   - Add `scripts/build-gbe-macos.sh` and `Native/GBEMac/`. Build the library from a pinned
     upstream commit, and pin its hashes.
   - Replace the library in one Unity and one non-Unity Steam macOS build, re-sign ad hoc, and reach
     gameplay without the Steam client.
   - The result decides whether FR-SMAC-6 ships in full or with the "no `libsteam_api` only" gate.
1. **Plumbing, no visible change:**
   - `SourceRegistry`, `SourceCapabilities`, `SourceID` and `GamePlatform`;
   - `InstallOwnership`/`RuntimeBinding` with legacy decoding;
   - `RuntimeEnvironment` in `RunningGame`;
   - `RunnerRegistry`;
   - the Steam helpers (store page, artwork fallback, cloud) moved behind the source;
   - generic copy instead of "Steam".

   Existing tests pass unchanged, and new tests cover decoding.
2. **Native runner:** `NativeRunner`, `inspect(root:)`, a fixture app and session tests.
3. **This Mac source:**
   - migration and tables;
   - scan, identity, and removed-entry revival;
   - `locate`;
   - Missing status;
   - Steam warning;
   - icon artwork.
4. **Steam macOS builds:**
   - `platforms` metadata;
   - resolve by platform;
   - file modes;
   - native plans in `InstallQueue`;
   - macOS staging and re-signing (per the spike);
   - platform switch.
5. **UI:**
   - the Stores page in Settings;
   - the This Mac picker and folders;
   - the rail Stores section;
   - Store and Platform filters;
   - tile glyphs;
   - install offer platform choice;
   - the game page: Store, Runs as, Switch, Remove, Locate, Rename;
   - empty states;
   - first-run changes;
   - captures.
6. **Docs:**
   - update 01 (§2 modules, §3 protocols, AR-PROTO-2 and AR-PROTO-4), 02 §3 and 04 §2;
   - update 05: §1, with FR-SRC-2/3 moving to v3, and §7, with FR-MAC-1 moving to v1 and
     FR-MAC-2/3/4 staying in v2;
   - update the README: "What you can do" and the "current focus" line;
   - tick the IMPLEMENTATION_PLAN items.

## Open questions

None open. Answers from 2026-09-26 are recorded as decisions 7–12.
