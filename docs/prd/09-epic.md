# PRD 09 — Epic Games Store

Journey: **install and play the games I own on Epic, from the couch**. This file makes Epic the
third store, after Steam and This Mac. It implements 08 FR-V3-4. Where this file and 08 §11
disagree about Epic, this file wins.

Drafted 2026-09-29 (Leo + Claude). The wire protocol is in [EPIC_PROTOCOL.md](../EPIC_PROTOCOL.md).
Every requirement here is tagged **v3** (this delivery, "the Epic MVP") or **later**.

## Decisions (dated 2026-09-29)

1. **Epic comes before itch.io and GOG, and before generic HTTP downloads (08 FR-V3-1).** Epic
   downloads the way Steam does: a manifest, then content-addressed chunks from a CDN. It does not
   need zip, dmg or installer unpacking.
2. **Sign-in is a code on the TV, finished on the phone.** Playden shows a short code and a QR
   code. The player approves it at `epicgames.com/activate` on their phone. The OAuth device flow is
   available only to console clients, so Playden signs in with the Nintendo Switch client and
   trades that session for a launcher session with a one-time exchange code (protocol §1b). The
   activation page is Fortnite-branded. This is expected, and the sign-in screen says so.
3. **Windows builds only.** Epic games install into a CrossOver bottle, like Steam Windows games.
   Epic macOS builds are **later**. They will reuse the platform choice and `NativeRunner` from 08 §4.
4. **No Epic cloud saves in the MVP.** They come right after it (**later**).
5. **Epic is another store in the merged library.** It gets a rail entry, a Store filter value, a
   tile badge and a Stores row in Settings, as This Mac does (08 decision 4). A game owned on Steam
   and on Epic shows as two tiles (08 FR-V3-7 stays **later**).
6. **The Epic launcher never runs.** Playden downloads the files and launches the game exe with
   the arguments the Epic launcher would pass.
7. **No game updates in the MVP.** Playden does not update Steam games either. Playden records
   the build version and CDN base URLs of each install, so updates can be added later.
8. **Games that need another launcher are not installable.** EA app, Ubisoft Connect and Unreal
   Marketplace items, and mods, are never offered for install.
9. **Client IDs and the user agent are compiled in and kept in one place.** Playden does not read
   legendary's remote config server. A remote override is **later**.
10. **legendary is the reference.** legendary (GPL-3) at commit
    `42f6bdeadde3a9526dc8eb713763476999ac217b` is ported where it helps. It is credited in
    `THIRD_PARTY_NOTICES.md`.

## 1. Architecture

- **AR-EPIC-1 (v3):** A new SwiftPM package, `Packages/EpicKit`, with one library, `EpicCore`. It
  holds the wire protocol: the HTTP client, the auth flows, the manifest and chunk parsers, and the
  download engine. It has no dependency on PlaydenKit. This matches the split between `SteamKit`
  and PlaydenKit's `Sources` module.
- **AR-EPIC-2 (v3):** `EpicSource`, `EpicAccount` and `EpicInstaller` live in PlaydenKit's
  `Sources` module and adapt `EpicCore` to `GameSource`, `SourceAuth` and `Installer`.
  `SourceID.epic == "epic"`. `GameID.value` is the Epic `appName`.
- **AR-EPIC-3 (v3):** `EpicClientConfig` holds the launcher client ID and secret, the Switch
  client ID and secret, and the user agent. It is the only place these values appear.
- **AR-EPIC-4 (v3):** Epic's zlib streams (manifests and chunks) have a 2-byte header and an
  Adler-32 trailer. Apple's `COMPRESSION_ZLIB` is raw deflate. `EpicCore` strips the header before
  it inflates, and it checks the result against the SHA-1 in the manifest.

### 1.1 Changes to shared code

These changes make a second account store work. Steam's behavior does not change.

- **AR-MULTI-1 (v3):** `SourceCapabilities.Account` gains `.deviceCode`. `SourceAuth` gains
  `signInWithDeviceCode(onEvent:)`. `AuthenticationEvent` gains
  `.deviceCode(userCode:verificationURL:expiresAt:)`. The default implementation throws
  `.unavailable`.
- **AR-MULTI-2 (v3):** Account state is per source (`LibraryModel.accounts`, keyed by source ID). `identity`, the sign-in screen, the sync error
  and "syncing" are keyed by source ID. Everything that asks the player to sign in again names the
  source, and "Sign in again" opens that source's sign-in:
  - `recordSyncFailure`;
  - `SessionRecovery`;
  - `installOfferRequiresSignIn`;
  - the queue's `.authentication` pause.
- **AR-MULTI-3 (v3):** Each remote source gets its own `LibrarySyncCoordinator`. A refresh of one
  store never cancels another store's refresh.
- **AR-MULTI-4 (v3):** `InstallQueue` and `SessionService` exist when any `.download` source is
  registered, not only when Steam is. First run asks for a games drive and CrossOver when any
  download store is signed in. A player with only Epic can install and play.
- **AR-MULTI-5 (v3):** `Installer` gains
  `prepareLaunch(_ spec: LaunchSpec, plan: InstallPlan, at: URL, offline: Bool) async throws -> LaunchSpec`.
  `SessionService.launchTracked` calls it right before `runner.launch`. The result is never
  persisted or logged. The default returns `spec` unchanged.
- **AR-MULTI-6 (v3):** A store that cannot start a game says why when the player presses Play.
  `prepareLaunch` throws an `OperationFailure` with the reason. The failure is reported on the
  game, like any other launch failure. Playden has no network monitor, so Play is not disabled in
  advance. Disabling Play ahead of time is **later**.
- **AR-MULTI-7 (v3):** The diagnostic redactor also removes exchange codes (`-AUTH_PASSWORD=`,
  `exchange_code=`), `-epicuserid=` and Epic refresh tokens.
- **AR-MULTI-8 (v3):** Credential storage is per source. Epic uses the Keychain service
  `<bundle id>.epic` with its own Codable payload: the refresh token, its expiry, the account ID
  and the display name. Access tokens stay in memory.
- **AR-MULTI-9 (v3):** `Game.coverFallbackURL` returns nil for non-Steam games, so an Epic game
  never falls back to a Steam CDN URL.

## 2. Sign-in

- **FR-EPIC-1 (v3):** Settings → Stores → Epic → Sign in, and the Epic card in first run, open a
  device-code screen. It shows:
  - the code in large type;
  - `epicgames.com/activate` as text;
  - a QR code for the full activation URL;
  - a countdown;
  - one line saying that the page shows Fortnite branding and that this is expected.
- **FR-EPIC-2 (v3):** Playden polls at the interval Epic returns. When the code expires, the screen
  offers a new code. Back cancels.
- **FR-EPIC-3 (v3):** After approval, Playden trades the Switch session for a launcher session
  (exchange code), ends the Switch session, stores the launcher refresh token (AR-MULTI-8) and
  refreshes the Epic library.
- **FR-EPIC-4 (v3):** Before each operation, Playden refreshes the access token when fewer than 10
  minutes remain. A rejected refresh token clears the credentials and shows "Sign in to Epic" with
  the source-scoped recovery (AR-MULTI-2). A network error keeps them.
- **FR-EPIC-5 (v3):** When Epic returns `corrective_action_required`, the Stores row shows "Epic
  needs you to accept updated terms." Showing the `continuationUrl` as a QR code is **later**.
- **FR-EPIC-6 (v3):** Sign out ends the launcher session on Epic, deletes the Keychain item and
  clears the Epic catalog only. Installed Epic games stay installed. Play asks the player to sign
  in again.

## 3. Library

- **FR-EPIC-7 (v3):** A library refresh lists the Windows assets
  (`/launcher/api/public/assets/Windows`) and adds catalog metadata for new or changed assets.
  Refresh runs on the Steam schedule: on launch, every 6 hours and from Settings.
- **FR-EPIC-8 (v3):** Playden skips these items:
  - the `ue` namespace (Unreal Marketplace);
  - items in the `mods` category;
  - DLC (`mainGameItem` is set);
  - library records that have no asset.
- **FR-EPIC-9 (v3):** Games that another launcher must install are not listed. These are games
  with `ThirdPartyManagedApp` or `ThirdPartyManagedProvider`, or with `partnerLinkType == ubisoft`.
  Showing them as "Needs the EA app" or "Needs Ubisoft Connect" is **later**.
- **FR-EPIC-10 (v3):** Records carry `platforms = [.windows]`, the title, the description and the
  artwork:
  - cover: `DieselGameBoxTall`, then `OfferImageTall`, then `Thumbnail`;
  - hero: `DieselGameBox`, then `OfferImageWide`, then `DieselStoreFrontWide`;
  - logo: `DieselGameBoxLogo`.
- **FR-EPIC-11 (v3):** The Epic payload that Playden keeps for each game has:
  - `namespace`, `catalogItemId` and `buildVersion`;
  - `CanRunOffline`, `OwnershipToken`, `FolderName`, `AdditionalCommandLine` and the sidecar
    deployment ID;
  - the third-party flags.

## 4. Install

- **FR-EPIC-12 (v3):** Install resolves the manifest through the manifest API, downloads it from
  the first CDN that answers, and checks its SHA-1 against the API's `hash`. Binary manifests
  (compressed, uncompressed and encrypted v22+) and JSON manifests are supported.
- **FR-EPIC-13 (v3):** The plan's estimate uses the chunk list: the download size is the total of
  the compressed chunk sizes, and the installed size is the total of the file sizes.
  The install offer shows it. The game page shows no size before the offer (**later**: an
  estimate from the manifest).
- **FR-EPIC-14 (v3):** The download fetches each unique chunk once, checks the SHA-1 of the
  decoded chunk, and writes each file from its chunk parts. It keeps a bounded cache of chunks that
  more than one file part still needs, and runs several requests in parallel. Failures are retried
  with backoff across all CDN base URLs.
- **FR-EPIC-15 (v3):** Pause, resume and relaunch-resume work as they do for Steam. A resume
  journal records each finished file with its SHA-1. On resume, Playden skips finished files that
  still exist.
- **FR-EPIC-16 (v3):** Verify files hashes each file with SHA-1 against the manifest. Repair
  downloads again only the missing and mismatched files.
- **FR-EPIC-17 (v3):** Playden saves the manifest with the install. Verify, repair and future
  updates read it from there. Uninstall uses the existing "delete the bottle" path.
- **FR-EPIC-18 (v3):** Paths are matched case-insensitively. `launch_exe` has `\` changed to `/`.
  A file with the executable flag is made executable.
- **FR-EPIC-19 (v3):** Encrypted chunks and manifests are decrypted with AES-GCM, using the keys
  that the manifest API returns. A build without keys (a preload) fails with
  "This game isn't released yet."
- **FR-EPIC-20 (v3):** Bottle names follow the existing rule: `playden-epic-<app name>` when the
  app name is lowercase letters, digits and dashes, and a hash of the ID otherwise. Lowercasing
  would let two app names that differ only in case share a bottle.
- **FR-EPIC-21 (later):** Game updates, delta manifests, install tags (selective downloads) and
  running the prerequisites that the manifest lists.

## 5. Play

- **FR-EPIC-22 (v3):** The launch spec is `launch_exe` with `launch_command` and
  `AdditionalCommandLine`. The working directory is the exe's folder. Right before each launch,
  `prepareLaunch` fetches a fresh exchange code and appends the Epic arguments in legendary's order
  (protocol §4):
  `-AUTH_LOGIN=unused -AUTH_PASSWORD=<code> -AUTH_TYPE=exchangecode -epicapp=<app> -epicenv=Prod -EpicPortal -epicusername=<name> -epicuserid=<id> -epiclocale=<lang> -epicsandboxid=<namespace> [-epicdeploymentid=<id>]`.
- **FR-EPIC-23 (v3):** Offline, or when the exchange code cannot be fetched because of a network
  error:
  - if the game has `CanRunOffline == false`, the launch stops with "Epic needs to be online to
    start this game." (AR-MULTI-6);
  - otherwise, the game launches with an empty `-AUTH_PASSWORD`.

  An expired sign-in shows "Sign in to Epic" instead.
- **FR-EPIC-24 (v3):** Games with `OwnershipToken == "true"` (usually Denuvo) get a `.ovt` token.
  Playden fetches it before launch, writes it inside the bottle, and passes its Windows path with
  `-epicovt=`. Offline, the launch stops with "Epic needs to be online to start this game."
  Whether Denuvo works under CrossOver is not guaranteed.
- **FR-EPIC-25 (v3):** When a game's files include `EasyAntiCheat`, `BEClient`, or `equ8.dll`, the
  game page shows "Uses anti-cheat that may not work in CrossOver." Playden does not block these
  games.
- **FR-EPIC-26 (later):** The EOS overlay, and running the manifest's prerequisites (VC++, DirectX)
  inside the bottle.

## 6. Tests and verification

- **FR-EPIC-T1 (v3):** `EpicCore` parser tests use a real public manifest and chunk from the EOS
  Overlay app (committed fixtures), plus synthetic manifests built in the tests for the JSON,
  compressed and encrypted variants. Fixtures never come from purchased games.
- **FR-EPIC-T2 (v3):** Auth, library and manifest API tests use `URLProtocol` stubs. They cover:
  - device-code pending, expiry and success;
  - redeeming the exchange code;
  - refresh and rejected refresh;
  - `corrective_action_required`;
  - library pagination and filtering.
- **FR-EPIC-T3 (v3):** Download tests serve synthetic chunks from a stub CDN. They cover shared
  chunks, resume after cancel, a CDN that fails over, a bad chunk hash, verify and repair.
- **FR-EPIC-T4 (v3):** Session tests cover `prepareLaunch` and the offline rules with a fake
  installer. App tests cover the device-code screen, Stores rows with two account stores,
  source-scoped sign-in recovery and an Epic-only first run.
- **FR-EPIC-T5 (v3):** `scripts/test.sh` runs the `EpicKit` tests.
- **Acceptance (manual):**
  - sign in from the couch;
  - see the Epic library with artwork;
  - install and play one non-EOS single-player game and one game that uses EOS sign-in;
  - quit and record playtime;
  - pause and resume a download across a relaunch;
  - verify files after deleting one;
  - play a `CanRunOffline` game with the network off.

  The test games avoid Denuvo (`OwnershipToken`) and anti-cheat.

## 7. Delivery order

Each step ships on its own and keeps Steam and This Mac working.

0. **Spike:** device-code sign-in → exchange code → launcher session, with a real account. The
   token then lists assets and the library and creates a launch exchange code.
1. **Docs:** this file, `EPIC_PROTOCOL.md`, the commit plan, and the legendary notice.
2. **`EpicCore` parsers:** manifests, chunks and chunk paths.
3. **`EpicCore` API:** auth, library, catalog, the manifest API, ownership tokens and the client
   config.
4. **`EpicCore` downloads:** the planner, the writer, the resume journal, verify and repair.
5. **Shared plumbing:** AR-MULTI-1 to AR-MULTI-9, with Steam unchanged.
6. **`EpicSource`:** account, library, installer and launch.
7. **UI:** the device-code screen, the Stores row, first run, unavailable and blocked states, and
   the anti-cheat notice.
8. **Acceptance and docs:** the manual acceptance above, the README and captures.

## Open questions

- The `.ovt` path under Wine (FR-EPIC-24) is untested. Write the token inside the bottle and pass a
  `C:\` path, then check it with a Denuvo game after the MVP.
