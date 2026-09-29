# PRD 10 — GOG

Journey: **install and play the games I own on GOG, from the couch**. This file makes GOG the
fourth store, after Steam, This Mac and Epic. It implements 08 FR-V3-3, without cloud saves. Where
this file and 08 §11 disagree about GOG, this file wins.

Drafted 2026-09-29 (Leo + Claude), on the `gog` branch, which starts from `epic`. The wire protocol
is in [GOG_PROTOCOL.md](../GOG_PROTOCOL.md). Every requirement here is tagged **v3** (this
delivery, "the GOG MVP") or **later**.

## Decisions (dated 2026-09-29)

1. **GOG comes after Epic and reuses its plumbing.** PRD 09 §1.1 (AR-MULTI-1 to AR-MULTI-9) made
   Playden work with several account stores. GOG is the second store that uses it. Epic's code is
   still being tested, so GOG does not refactor it. A download engine shared by Epic and GOG is
   **later**, once both have passed acceptance.
2. **Sign-in: a QR code on the TV, finished on the phone, with a login window as the fallback.** GOG
   has no device-code flow. Its login always ends on the fixed page
   `embed.gog.com/on_login_success`, and the code is in that page's address. So:
   - Playden serves a small sign-in page on the local network and shows a QR code for it. On the
     phone, the page opens GOG's login in a new tab. After login, the player copies the address of
     the page they land on and pastes it into the Playden page.
   - "Sign in on this Mac" opens GOG's login in a Playden window, which catches the redirect itself.
     This is what Heroic does. It needs a keyboard, so it is the fallback.
   - GOG accepts no other redirect address (step 0: `redirect_uri_mismatch`), so the paste step
     stays.
3. **Windows and macOS builds.** Windows builds install into a CrossOver bottle, like Epic games.
   macOS builds use the platform choice, the owned install folder and `NativeRunner` from Steam
   macOS builds (08 §4). A game with both builds offers the same choice as a Steam game.
4. **Downloads use the Galaxy content system, generation 2 and generation 1.** Generation 2 has
   chunked depot manifests (zlib, MD5), close to Epic's. Generation 1 covers older games: each file
   is a byte range of one large blob. Offline installers (`setup_*.exe`, `.pkg`) are not used.
5. **No GOG cloud saves in the MVP.** They come right after it (**later**), as for Epic.
6. **GOG is another store in the merged library.** It gets a rail entry, a Store filter value, a
   tile badge and a Stores row in Settings, as Epic does. A game owned on GOG and on another store
   shows as two tiles (08 FR-V3-7 stays **later**).
7. **No Galaxy client at runtime.** GOG games are DRM-free. Playden downloads the files and
   launches the game. It does not emulate the Galaxy communication service (Heroic's `comet`), so
   games that use the Galaxy SDK lose achievements and online features. Emulating it is **later**.
8. **No game updates in the MVP.** Playden records the build ID, and saves the manifests with the
   install, so updates can be added later.
9. **Client ID and secret are compiled in and kept in one place.** These are the Galaxy client
   values that gogdl, Heroic, lgogdownloader and minigalaxy all use.
10. **gogdl is the reference.** gogdl (GPL-3) at commit
    `9c593fdba2a3e829a48e45e6475d8db937833dce` is ported where it helps. It is credited in
    `THIRD_PARTY_NOTICES.md`. lgogdownloader (WTFPL) and minigalaxy (GPL-3) are used to check
    details. GOG_PROTOCOL.md lists gogdl bugs that the port must not copy.

## Lessons from Epic

What the Epic MVP and its testing taught, and how this plan applies it:

- **Spike with a real account before building.** Epic's spike found the "accept updated terms"
  step that no source mentioned. GOG has six unconfirmed protocol details (GOG_PROTOCOL.md, "Open
  items"), and two of them change the design. Step 0 answers them first.
- **The sign-in screen works away from the TV too.** The link is clickable, and anything the
  player has to copy has a copy button (FR-GOG-1).
- **Recovery prompts name the store and the thing that stopped.** For example, "Downloads paused ·
  Sign in to GOG", not a bare "Sign in" (FR-GOG-5).
- **Bottle names are not lowercased.** GOG product IDs are digits, so the existing rule already
  gives `playden-gog-<product id>`.
- **Check decoded content while downloading, not only at repair.** gogdl checks only the
  compressed MD5 during a download. Playden checks both hashes (FR-GOG-15).
- **Test fixtures never come from purchased games.** GOG's public dependency store plays the part
  that the EOS Overlay played for Epic (FR-GOG-T1).
- **Pick the test games early from the real library.** The step 0 spike lists the account's
  games and picks one of each kind that acceptance needs (§6).
- **Epic's controller-only pass on the TV is still open.** GOG's acceptance includes one, and the
  two can be done together.

## 1. Architecture

- **AR-GOG-1 (v3):** A new SwiftPM package, `Packages/GOGKit`, with one library, `GOGCore`, and a
  `gog-dev` executable for live testing. `GOGCore` holds the wire protocol: the HTTP client, the
  auth calls, the library and builds APIs, the gen 1 and gen 2 manifest parsers, and the download
  engine. It has no dependency on PlaydenKit or on `EpicCore`.
- **AR-GOG-2 (v3):** `GOGSource`, `GOGAccount` and `GOGInstaller` live in PlaydenKit's `Sources`
  module and adapt `GOGCore` to `GameSource`, `SourceAuth` and `Installer`.
  `SourceID.gog == "gog"`. `GameID.value` is the GOG product ID.
- **AR-GOG-3 (v3):** `GOGClientConfig` holds the Galaxy client ID and secret, the hosts and the
  user agent (`Playden/<version>`, an honest one; GOG requires none). It is the only place these
  values appear.
- **AR-GOG-4 (v3):** GOG's zlib streams (gen 2 manifests and chunks) have the standard zlib header.
  `GOGCore` inflates them with `libz`, as `EpicCore` does. Gen 1 manifests are plain JSON.

### 1.1 Changes to shared code

These changes add a second kind of browser sign-in. Steam's and Epic's behavior does not change.

- **AR-MULTI-10 (v3):** `SourceCapabilities.Account` gains `.webLogin`. `SourceAuth` gains:
  - `webLoginURL() -> URL`, the store's login page;
  - `redirectMatches(_ url: URL) -> Bool`, true for the page the login ends on;
  - `signIn(withRedirect url: URL) async throws -> SourceIdentity`, which reads the code from
    that address, or from a bare code, and finishes the sign-in.

  The default implementations throw `.unavailable`.
- **AR-MULTI-11 (v3):** A store-neutral `SignInRelay` in PlaydenKit serves the phone page:
  - an `NWListener` on a random port, plain HTTP, on the Mac's current LAN address (Wi-Fi or
    Ethernet, whichever has the default route);
  - one page and one form POST, under a path that carries a random one-time token;
  - it accepts only a pasted address or code, which it hands to `signIn(withRedirect:)`;
  - it stops on success, on Back and after 10 minutes;
  - it never logs the pasted value.

  The page's "Open GOG sign-in" link opens in a new tab, so the Playden page stays open for the
  paste. Other stores without a device flow (itch.io, Amazon) can reuse the relay.
- **AR-MULTI-12 (v3):** `AuthenticationScreen` gains a `.webLogin` state. The in-app login window
  is a `WKWebView` that watches navigation (`decidePolicyFor`) and cancels the navigation to the
  redirect page once `redirectMatches` is true.
- **AR-MULTI-13 (v3):** Local network use is declared. The app's `Info.plist` gets
  `NSLocalNetworkUsageDescription`. Step 5 records which prompts macOS shows (local network,
  firewall) the first time the relay serves a phone. The prompts belong to the Playden app, so the
  spike tool could not show them.
- **AR-MULTI-14 (v3):** The diagnostic redactor also removes GOG codes (`code=` in any URL),
  `access_token`, `refresh_token`, `user_id`, and the signed query of secure-link URLs.
- **AR-MULTI-15 (v3):** Credential storage for GOG uses the Keychain service `<bundle id>.gog`
  with its own Codable payload: the refresh token, the user ID and the display name. Access
  tokens stay in memory.

## 2. Sign-in

- **FR-GOG-1 (v3):** Settings → Stores → GOG → Sign in, and the GOG card in first run, open the
  web-login screen. It shows:
  - a QR code for the relay page, and its address as text (clickable, with a copy button);
  - three short steps: "Scan with your phone", "Sign in to GOG", "Paste the address you land on";
  - "Sign in on this Mac", which opens the login window;
  - a paste field, for a player who signed in on another computer.
- **FR-GOG-2 (v3):** The relay page on the phone has the "Open GOG sign-in" link, a paste field
  and a Send button. It says where the address is ("the page that opens after you sign in") and
  shows the result: "Signed in. You can close this page." or the reason it failed.
- **FR-GOG-3 (v3):** After the code arrives, Playden exchanges it for tokens (authorization-code
  grant), reads the display name, stores the refresh token (AR-MULTI-15) and refreshes the GOG
  library. A wrong or used code shows "That address didn't work. Sign in again and paste the new
  one." and keeps the screen open.
- **FR-GOG-4 (v3):** Before each operation, Playden refreshes the access token when fewer than 10
  minutes remain, and stores the new refresh token each time. A rejected refresh token clears the
  credentials and shows "Sign in to GOG" with the source-scoped recovery (AR-MULTI-2). A network
  error keeps them.
- **FR-GOG-5 (v3):** A download that stops because the sign-in expired pauses with "Downloads
  paused · Sign in to GOG".
- **FR-GOG-6 (v3):** Sign out deletes the Keychain item and clears the GOG catalog only. GOG has
  no session to end. Installed GOG games stay installed and still play, because GOG games need no
  sign-in to start.

## 3. Library

- **FR-GOG-7 (v3):** A library refresh lists the owned product IDs and reads each product from
  gamesdb (`gamesdb.gog.com/platforms/gog/external_releases/<id>`). Refresh runs on the Steam
  schedule: on launch, every 6 hours and from Settings. The owned IDs come from
  `embed.gog.com/user/data/games`, which step 0 found as complete as the paged `galaxy-library`
  list.
- **FR-GOG-8 (v3):** Playden keeps items with `type` `game` and `visible_in_library`. It skips DLC,
  `mod`, `spam`, and products without a gamesdb entry.
- **FR-GOG-9 (v3):** Records carry the title, the summary, the genres and the release date.
  `platforms` comes from `supported_operating_systems`: `windows` → Windows, `osx` → macOS. The
  builds API is authoritative at resolve time (FR-SMAC-1 pattern). A game whose data says macOS
  but that has no macOS build falls back to Windows, and the install offer says why.
- **FR-GOG-10 (v3):** Artwork comes from gamesdb `url_format` values, with `{formatter}` replaced by
  `""` and `{ext}` by `jpg`. The `?namespace=gamesdb` query is kept:
  - cover: `game.vertical_cover`;
  - hero: `game.background`, then `game.horizontal_artwork`;
  - logo: the v2 products API `_links.logo`, when it is a PNG (**UNCONFIRMED** that it is always
    transparent; no logo otherwise).
- **FR-GOG-11 (v3):** Product data is cached on disk per product with its ETag, and refreshed with
  `If-None-Match`, so a library of hundreds of games costs one short request per game.
- **FR-GOG-12 (v3):** Owned DLC is not shown as tiles. Its IDs are kept, so install can include the
  DLC depots (FR-GOG-14).

## 4. Install

- **FR-GOG-13 (v3):** Resolve asks for
  `content-system.gog.com/products/<id>/os/<windows|osx>/builds?generation=2&_version=2`, takes the
  first build on the default branch (`branch == null`), and reads its `generation`. It downloads
  the build manifest from the first CDN that answers, in the order the response lists them.
- **FR-GOG-14 (v3):** Depot selection:
  - the base game's depots and the depots of owned DLC;
  - the language: the depot lists `*` (gen 2), `Neutral` (gen 1) or the install language. The
    install language maps Playden's language to GOG's (`english` → `en-US`, `English`), and falls
    back to English when the game lacks it;
  - bitness: 64-bit depots, or depots that do not say.

  The plan's estimate: the download size is the total compressed size of the chosen depots, and the
  installed size is the total file size. The install offer shows it.
- **FR-GOG-15 (v3):** Gen 2 downloads:
  - one secure link per product (the base game and each owned DLC), fetched again on a 401 or 403;
  - chunks fetched in parallel, with retries and backoff across the listed CDNs;
  - each chunk checked against `compressedMd5`, inflated, and checked against `md5`;
  - files written in chunk order, then checked against the file's `md5` or `sha256` when the
    manifest has one;
  - a chunk that more than one file uses is fetched again for each use. This is rare in GOG
    builds, and it keeps memory bounded by the fetch window;
  - the small-files container is ignored, because every file also lists its own chunks.
- **FR-GOG-16 (v3):** Gen 1 downloads:
  - one secure link for the depot path, fetched again on a 401 or 403;
  - each file fetched as byte ranges of `main.bin`, in ranges of at most 10 MiB;
  - each file checked against its whole-file MD5 after it is written;
  - symlink records (`symlinkType`) created as links that must resolve inside the game folder;
  - the `executable` flag applied (gogdl's typo skips it).
- **FR-GOG-17 (v3):** Pause, resume and relaunch-resume work as they do for Epic. A resume journal
  records each finished file with its hash. On resume, Playden skips finished files that still
  exist.
- **FR-GOG-18 (v3):** Verify files hashes each file against the manifest. A gen 2 file without a
  whole-file hash is checked chunk by chunk. Repair downloads again only the missing and
  mismatched files.
- **FR-GOG-19 (v3):** Playden saves the build manifest and depot manifests in `.playden-gog/` in the
  install folder. Verify, repair and future updates read them from there. Uninstall uses the
  existing paths: delete the bottle for Windows, delete the owned folder for macOS.
- **FR-GOG-20 (v3):** Paths change `\` to `/`, lose a leading `/`, and are matched
  case-insensitively. Paths that leave the install folder are refused. Files with the `support`
  flag go to `.playden-gog/support/<product id>/`, except those under `app/`, which go into the
  game folder as Galaxy's install script places them. DOSBox and ScummVM games keep their
  configs there (found in acceptance: Arena's `dosbox_arena.conf`).
- **FR-GOG-21 (v3):** Game-folder dependencies are installed with the game. These are entries of
  the build's `dependencies` whose executable path is empty, such as DOSBox and ScummVM. Without
  them, those games have no executable. They come from the public dependency store.
- **FR-GOG-21a (v3):** After a Windows install, Playden runs the file steps of each product's
  `goggame-<id>.script`, the steps Galaxy's script interpreter (ISI) would run:
  - `supportData` copies a support folder into the game folder (never over an existing file unless
    the script says to overwrite), or creates a folder;
  - `setIni` sets a key in an INI file, such as ScummVM's game `path`. `{app}` in values is the
    game folder as Wine sees it (`Z:\…`).

  Before each launch, the INI keys and folders are set again, so paths follow a moved games drive.
  Copies run only at install. Verify files accepts the INI files a script changed, and still reports
  a missing one so repair restores it. Paths must stay
  in the game or support folder. (Found in acceptance: Beneath a Steel Sky's `beneath.ini` has no
  game path until the script sets it.)
- **FR-GOG-22 (later):** Redistributable installers (`__redist`: MSVC, DirectX, PhysX), the
  script's `setRegistry` steps, running the ISI itself (`scriptInterpreter`) and gen 1
  `support_commands`. In acceptance, Monkey Island 2 Special Edition crashed at start. It lists
  DirectX, .NET 3.5 and MSVC2008 installers that Playden doesn't run, the likely cause, so this is
  the first follow-up. The plan keeps the
  `dependencies` list, so these can be added later through the existing `RuntimePrerequisite`
  path that Steam uses. CrossOver's built-in runtimes cover most modern games.
- **FR-GOG-23 (later):** Game updates (chunk reuse and xdelta patches), private branches, and
  choosing a build other than the newest.

## 5. Play

- **FR-GOG-24 (v3):** The launch spec comes from the base product's `goggame-<id>.info`:
  - the first `FileTask` with `isPrimary`, else the first `FileTask`. A `URLTask` is never
    launched;
  - the working directory is `workingDir`, else the exe's folder;
  - `arguments` split with the platform's rules: `WindowsArguments` for Windows builds, POSIX
    shell words for macOS builds;
  - other `FileTask`s that are not hidden and not documents become launch options (the existing
    `launchOptions`).

  The info file is at the install root (Windows gen 2), in `Contents/Resources/` (macOS gen 2), or
  hidden as `.goggame-<id>.info` (macOS gen 1).
- **FR-GOG-25 (v3):** Windows builds run in a CrossOver bottle named `playden-gog-<product id>`.
  `prepareLaunch` keeps the default: GOG adds nothing to a launch and needs no network.
- **FR-GOG-26 (v3):** macOS builds follow FR-SMAC-4, FR-SMAC-5, FR-SMAC-8 and FR-SMAC-10:
  - the install root is the app bundle (step 0), so the install folder is `<name>.app`, and the
    primary task's path (`Contents/MacOS/<exe>`) must be inside it with an `Info.plist`;
  - Mach-O files under `Contents/MacOS` and files with the `executable` flag become `0o755`;
  - an x86_64-only build needs Rosetta, and Play explains how to install it;
  - `NativeRunner` runs the bundle from the owned folder.

  ScummVM and DOSBox Mac builds are GOG wrapper bundles (`GOGLauncher`, `Launcher`) that start the
  bundled emulator. Playden runs the bundle as it is; the session follows the emulator process,
  which runs from inside the bundle. Gen 1 Mac builds (a wrapper with the real game in
  `Contents/Resources/game/`) were not in the test library. They are installed the same way, and
  a gen 1 Mac game that fails is reported through its compatibility rating.
- **FR-GOG-27 (v3):** Validate checks the Mach-O architectures of a macOS build. A build with only
  32-bit code can't run on current macOS. It fails with "This Mac version is 32-bit and can't run
  on this macOS. Switch to the Windows version." when the game has one.
- **FR-GOG-28 (v3):** Playden does not re-sign GOG Mac builds. GOG adds files to bundles after
  signing, so `codesign --verify` often fails, but unsigned, broken-seal x86_64 and broken-seal
  arm64 bundles all started through LaunchServices in step 0. Validation does not check the
  signature. If a build fails to start because of its signature, an ad-hoc re-sign (FR-SMAC-7)
  is the fix, **later**.
- **FR-GOG-29 (later):** A Galaxy communication service in the bottle (Heroic's `comet`), for
  achievements and online features; native DOSBox and ScummVM in place of the bundled Windows ones.

## 6. Tests and verification

- **FR-GOG-T1 (v3):** `GOGCore` parser tests use public data only:
  - a build manifest and depot manifest of a public product (manifests are file lists, not game
    content);
  - chunks from the public dependency store (no sign-in, unsigned URLs);
  - synthetic gen 1 and gen 2 manifests built in the tests.

  Fixtures never contain content from purchased games.
- **FR-GOG-T2 (v3):** Auth, library and builds API tests use `URLProtocol` stubs. They cover:
  - reading the code from a redirect address and from a bare code;
  - the code exchange, refresh, and a rejected refresh;
  - the builds list with mixed generations and branches;
  - gamesdb filtering and artwork;
  - a secure link that expires during a download.
- **FR-GOG-T3 (v3):** Download tests serve synthetic chunks and a synthetic `main.bin` from a stub
  CDN. They cover shared chunks, resume after cancel, a CDN that fails over, a bad compressed hash,
  a bad inflated hash, gen 1 ranges and symlinks, verify and repair.
- **FR-GOG-T4 (v3):** `SignInRelay` tests use a real listener on the loopback address: the page,
  the POST, a wrong token, and stopping. App tests cover the web-login screen, the Stores row with
  three account stores, a GOG-only first run and the macOS platform offer for a GOG game.
- **FR-GOG-T5 (v3):** `scripts/test.sh` runs the `GOGKit` tests.
- **Acceptance (manual):**
  - sign in from the couch with the phone relay;
  - sign in with the login window;
  - see the GOG library with artwork;
  - install and play these games from the account (picked in step 0):
    - gen 2 Windows, no dependencies: Jazz Jackrabbit 2: The Secret Files (0.1 GB);
    - gen 1 Windows: Monkey Island 2 Special Edition. It lists `__redist` dependencies (DirectX,
      .NET 3.5, MSVC2008) that the MVP skips (FR-GOG-22), so it also tests that rule;
    - native Mac: VirtuaVerse (arm64) and Flashback (x86_64, Rosetta);
    - DOSBox and ScummVM: The Elder Scrolls: Arena (Windows, `DOSBox074_2CS`), and Beneath a Steel
      Sky (Windows `ScummVM` dependency, Mac wrapper);
  - quit and record playtime;
  - pause and resume a download across a relaunch;
  - verify files after deleting one;
  - with the network off, start an installed game;
  - a controller-only pass on the TV, together with Epic's.

### Acceptance results (2026-09-30, this Mac, keyboard)

| Check | Result |
|---|---|
| Phone relay sign-in | Passed with a desktop browser on the LAN address (`10.0.1.72`), then with the player's phone (reported by the player, 2026-09-30). |
| Login window sign-in | Passed with the player's GOG account (reported by the player, 2026-09-30). |
| Library | 23 GOG games with covers, heroes and platforms. |
| Jazz Jackrabbit 2: The Secret Files (gen 2 Windows) | Installed (53 MB) and started; the process runs in its bottle, but its window never becomes visible. Its script also sets registry keys, which Playden skips (FR-GOG-22). Rated as a compatibility issue. |
| Monkey Island 2 Special Edition (gen 1 Windows) | Installed (1.9 GB). Resumed after Playden was force-killed at 1.6 GB. Verify files found and restored a deleted `monkey2.exe`. The game crashes at start (Wine's debugger caught it); it lists DirectX, .NET 3.5 and MSVC2008 installers Playden doesn't run, the likely cause (FR-GOG-22). |
| VirtuaVerse (Mac, arm64) | Installed and played natively to the main menu; the session ended cleanly. |
| Flashback (Mac, x86_64) | Installed and played through Rosetta (Unity setup dialog, then the intro); ended cleanly with 206 s recorded. |
| The Elder Scrolls: Arena (DOSBox) | Played to the intro once the `app/` support rule put its configs in the game folder. |
| Beneath a Steel Sky (Windows, ScummVM) | Played to the intro once FR-GOG-21a set the game path in `beneath.ini`. |
| Uninstall | First try (Arena) showed a Cloud warning for a store without cloud saves; after the fix, Jazz Jackrabbit 2 uninstalled with one confirmation. |
| Offline start | Not tried on the network; GOG adds nothing to a launch, and a unit test covers the offline case. |
| Controller-only TV pass | Done by the player on the Release build in `/Applications` (2026-09-30): Flashback and VirtuaVerse sessions ended cleanly (42 s and 32 s recorded). |

## 7. Delivery order

Each step ships on its own and keeps Steam, This Mac and Epic working.

0. **Spike:** `gog-dev sign-in` with a real account, then the open items in GOG_PROTOCOL.md: the
   redirect address, token lifetime and refresh rotation, the secure-link shape and lifetime,
   macOS `playTasks` paths and code signatures, the library endpoints, and the test games.
1. **Docs:** this file, GOG_PROTOCOL.md, the commit plan, and the gogdl notice.
2. **`GOGCore` parsers:** builds, gen 1 and gen 2 manifests, the info file, and dependencies.
3. **`GOGCore` API:** auth, library, gamesdb, builds, secure links and the client config.
4. **`GOGCore` downloads:** gen 2 and gen 1 downloads, the resume journal, verify and repair.
5. **Shared plumbing:** AR-MULTI-10 to AR-MULTI-15, with Steam and Epic unchanged.
6. **`GOGSource`:** account, library, installer and launch, for Windows builds.
7. **macOS builds:** resolve, preparation, validation and launch for GOG Mac builds.
8. **UI:** the web-login screen, the relay page, the login window, the Stores row and first run.
9. **Acceptance and docs:** the manual acceptance above, the README and captures.

## Open questions

Step 0 answered the redirect, token, secure-link, launch-task and signature questions; see
GOG_PROTOCOL.md, "Spike results". Still open:

- Which prompts, if any, macOS shows the first time a phone opens the relay page (not reported).
- Why Jazz Jackrabbit 2's window stays hidden, and whether its registry keys fix it.
- The install offer defaults to the last games drive even when This Mac was chosen for the
  previous game; the player picks This Mac each time (existing behavior, not GOG-specific).
- The builds list returns 10 items. Playden needs only the first default-branch build, so paging
  matters only for choosing older builds (**later**).
