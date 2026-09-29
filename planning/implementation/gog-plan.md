# GOG — commit plan

Requirements: [PRD 10](../../docs/prd/10-gog.md). Protocol: [GOG_PROTOCOL.md](../../docs/GOG_PROTOCOL.md).
Branch: `gog`, started from `epic`. Commit each step once it builds and its tests pass. Mark steps
done here and commit this file with them.

Live testing uses `.gog-session.json` in the repo root (gitignored). It holds a Galaxy session
created by `scripts/gog-sign-in.sh` (the `gog-dev` tool in `GOGKit`). The tool prints the login URL,
the player signs in in any browser and pastes back the address they land on (or just the code).
Anything that refreshes the session must write the new refresh token back.

## Step 0 — Spike with a real account

Run `! scripts/gog-sign-in.sh` (prints the login URL), then `! scripts/gog-sign-in.sh '<address>'`.
`scripts/gog-sign-in.sh check` refreshes the session and writes `.gog-library.tsv` (gitignored).
`gog-dev info <session> <product> <windows|osx>` shows a build's CDNs, secure link and launch
tasks; `gog-dev download <session> <product> <os> <dir>` is a plain gen 2 download for checks.
Answers are in GOG_PROTOCOL.md, "Spike results".

- [x] `gog-dev` in `Packages/GOGKit` (`url`, `sign-in`, `listen`, `check`, `info`, `download`) and
  `scripts/gog-sign-in.sh`.
- [x] Redirect address: GOG refuses any other `redirect_uri` at login (`redirect_uri_mismatch`), so
  the relay page keeps the paste step.
- [x] Tokens last 3600 s. No refresh-token rotation seen.
- [x] Secure links: `fastly` and `gcore` templates recorded; links last 24 hours. The answer for a
  product the account does not own was not checked (the library has none to try).
- [x] Library: the embed list (27) plus the gamesdb filter (23 games, 4 `spam`) is enough.
- [x] macOS: the install root is the bundle; tasks are `Contents/MacOS/<exe>`. Signatures are
  missing or broken (GOG adds files after signing), and all three test builds still start through
  LaunchServices, so no re-signing. No gen 1 Mac build in the library.
- [ ] The relay prompts (local network, firewall): moved to step 5, since they belong to the app.
- [x] Acceptance games picked (PRD 10 §6).

Done 2026-09-29 with a real account.

## Step 1 — Docs

- [x] `docs/prd/10-gog.md`, `docs/GOG_PROTOCOL.md`, this plan.
- [x] PRD README row. 08 §11 GOG row and FR-V3-3 point to PRD 10. IMPLEMENTATION_PLAN M9.
- [x] `THIRD_PARTY_NOTICES.md`: gogdl (GPL-3) at `9c593fdba2a3e829a48e45e6475d8db937833dce`.
- [x] `.gitignore`: `.gog-session.json`.

## Step 2 — `GOGCore` parsers (`Packages/GOGKit`)

- [x] `Package.swift` with the `GOGCore` library, `GOGCoreTests` and `gog-dev`. Link `libz`.
- [x] `GOGCodec`: zlib inflate (header required), MD5, the `galaxy_path` helper (`ab/cd/abcd…`).
- [x] `GOGBuilds`: the builds list (both generations, `urls[]`, `branch`), and choosing the first
  default-branch build.
- [x] `GOGManifestV2`: the build manifest (depots, `products`, `dependencies`, `installDirectory`,
  `osBitness`) and depot manifests (`DepotFile`, `DepotDirectory`, `DepotLink`, flags). Paths
  normalized. `sfcRef` parsed and ignored.
- [x] `GOGManifestV1`: the repository (string sizes, `redist` depots skipped) and depot manifests
  (files, directories, `symlinkType` records without a size).
- [x] Depot selection: base plus owned DLC, language (`*`, `Neutral`, code, English name), bitness.
- [x] `GOGInfoFile`: `playTasks`, the primary task, launch options, and the three locations.
- [x] `GOGDependencies`: the repository manifest, and game-folder entries (empty executable path).
- [x] Fixtures: a public product's build and depot manifests, and one small chunk from the public
  dependency store. Synthetic gen 1 and gen 2 manifests built in the tests.
- [x] `scripts/test.sh` runs `swift test --package-path Packages/GOGKit`.

Done 2026-09-29. Both generations flatten into one `GOGInstallManifest` (a list of `GOGFile`), so
download, verify and repair share one path. Fixtures are public: Prison Architect's build and DLC
depot manifests, Monkey Island 2 Special Edition's gen 1 repository, the dependency repository,
and one DOSBox documentation chunk.

## Step 3 — `GOGCore` API

- [x] `GOGClientConfig` (client ID and secret, hosts, user agent) and `GOGHTTP` (bearer auth,
  GOG error JSON → `GOGError`, 429/5xx backoff, timeouts that let IPv6 fall back).
- [x] `GOGAuth`: the login URL, reading the code from a redirect address or a bare code, the code
  exchange, refresh with a 10-minute margin, and saving the rotated refresh token.
- [x] `GOGLibraryAPI`: owned IDs, gamesdb with ETag, the v2 products API logo, the user's name.
- [x] `GOGContentAPI`: builds, build and depot manifests from the CDN list, secure links per
  product (gen 2) and per depot path (gen 1), and the dependency `open_link`.
- [x] Tests with `URLProtocol` stubs.
- [x] Live tests gated on `GOG_LIVE=1`: download and verify a public dependency depot (no account);
  refresh `.gog-session.json`, list the library, resolve a build and fetch a secure link.

## Step 4 — `GOGCore` downloads

- [x] `GOGDownloadPlan`: files from the chosen depots in order, chunk use counts, sizes, and the
  game-folder dependency depots.
- [x] `GOGDownloader` for gen 2:
  - parallel chunk fetches over the CDN list, with retry and backoff;
  - a secure link fetched again on a 401 or 403;
  - both MD5 checks per chunk, then the file's `md5` or `sha256`;
  - shared chunks fetched again for each use (rare; keeps memory bounded);
  - a resume journal in `.gog-download/resume`;
  - progress callbacks and cancellation;
  - directories, links inside the folder, executable bits, empty files, `support` files;
  - case-insensitive target paths.
- [x] `GOGDownloader` for gen 1: `main.bin` ranges of at most 10 MiB, the whole-file MD5, symlink
  records, executable bits, the same journal.
- [x] `invalidFiles(in:)` for both generations (chunk-by-chunk when a gen 2 file has no hash), and
  `repair`, which downloads only those files.
- [x] Tests against a stub CDN with synthetic chunks and a synthetic `main.bin`.

Done 2026-09-29. The live tests download, verify and repair DOSBox from the public dependency
store, and resolve VirtuaVerse (Mac, gen 2, 348 MB) and Monkey Island 2 Special Edition (Windows,
gen 1, 1.9 GB) with the account, reading each launch task through its secure link.

## Step 5 — Shared plumbing (PlaydenKit + App), Steam and Epic unchanged

- [x] `SourceID.gog`. `Account.webLogin`. `SourceAuth.webLoginURL`, `redirectMatches` and
  `signIn(withRedirect:)`.
- [x] `SignInRelay` (`NWListener`, one-time token, one page and one POST, 10-minute limit).
  `NSLocalNetworkUsageDescription`.
- [x] `AuthenticationScreen.webLogin`: with the UI in step 8.
- [x] Redactor: GOG codes, access and refresh tokens, `user_id`, signed secure-link queries.
- [x] Existing tests pass (PlaydenKit 425). New tests: the relay on loopback, the redactor. Three
  account stores are covered by the app tests in step 8.

## Step 6 — `GOGSource` (PlaydenKit `Sources`), Windows builds

- [x] `GOGAccount`: a `SourceAuth` actor with Keychain `<bundle>.gog`, the web-login sign-in,
  refresh before each operation, and error mapping to `SourceFailure`.
- [x] `GOGSource`: `ownedGames` (owned IDs plus gamesdb, filtered), metadata, artwork, platforms,
  and the gamesdb cache on disk.
- [x] `GOGInstaller` for Windows: `resolve` (builds → `InstallPlan` with the payload), download,
  verify, repair, the game-folder dependencies, validate (the info file, the exe exists, matched
  case-insensitively), launch options.
- [x] Register it in `PlaydenApp`. `StoreNames` gets "GOG" and a glyph.
- [x] Tests mirroring `EpicSourceTests` with a fixture backend. Live install test gated on
  `GOG_LIVE_INSTALL`.

Done 2026-09-29. `GOG_LIVE=1 swift test --filter GOGLiveTests` lists 23 games and resolves all 37
plans (23 Windows, 14 Mac) with their launch tasks; `GOG_LIVE_INSTALL=1351891846` downloads,
verifies and validates Jazz Jackrabbit 2: The Secret Files.

## Step 7 — macOS builds

- [x] `resolve(platform: .macOS)` with the `osx` builds; the offer falls back to Windows when there
  is no Mac build.
- [x] Preparation: file modes, the `.app` normalization, and no re-signing (step 0: the bundles start as
  GOG ships them).
- [x] Validation: the Mach-O architectures (32-bit only fails with a reason; x86_64 only needs
  Rosetta). Gen 1 wrappers run as they are.
- [x] Launch through `NativeRunner`. Uninstall deletes the owned folder.
- [x] Tests with synthetic Mac manifests and a small Mach-O fixture.

Done 2026-09-29. `GOG_LIVE_INSTALL=1207658901:osx` (Tyrian 2000) and `2116968103:osx` (VirtuaVerse)
download, verify and validate as `<name>.app` bundles.

## Step 8 — UI

- [x] The web-login screen: the QR code and relay address (clickable, copyable), the three steps,
  "Sign in on this Mac", the paste field.
- [x] The relay page (HTML served by `SignInRelay`), readable on a phone.
- [x] The login window (`WKWebView`, catches the redirect).
- [x] The Stores row for GOG (Sign in/out, Refresh, last sync or error). The first-run GOG card.
- [x] App tests. A `signin-web-login` snapshot.

Done 2026-09-29. The login window passes its keys to the page (the launcher's keyboard monitor
skips it) and uses a private, non-persistent web session. App tests run the relay on loopback.

## Step 9 — Acceptance and docs

- [x] Sign in with the phone relay: done from a desktop browser on the LAN address; a real phone
  and the login window with a real account are still to try.
- [x] Install and play from the UI on this Mac: VirtuaVerse, Flashback, Arena and Beneath a Steel
  Sky play; Jazz Jackrabbit 2 starts without a visible window; Monkey Island 2 Special Edition
  needs its redistributables. Playtime and exit results recorded. Results table in PRD 10 §6.
- [x] Resume after a crash (Monkey Island 2 Special Edition, force-killed at 1.6 GB); verify files
  after deleting one (restored `monkey2.exe`). Offline start: unit test only.
- [ ] Controller-only pass on the TV, together with Epic's.
- [x] README "What you can do" and the current-focus line. Captures: the `signin-web-login`
  snapshot.

Fixes found in acceptance and committed with it:
- support files under `app/` go into the game folder (Arena's DOSBox configs);
- the install script's file steps run after install and before each launch (Beneath a Steel
  Sky's ScummVM path);
- uninstall of a store without cloud saves needs one confirmation, and the platform picker and
  uninstall review no longer mention Steam Cloud for those stores.
