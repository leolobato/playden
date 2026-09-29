# GOG — commit plan

Requirements: [PRD 10](../../docs/prd/10-gog.md). Protocol: [GOG_PROTOCOL.md](../../docs/GOG_PROTOCOL.md).
Branch: `gog`, started from `epic`. Commit each step once it builds and its tests pass. Mark steps
done here and commit this file with them.

Live testing uses `.gog-session.json` in the repo root (gitignored). It holds a Galaxy session
created by `scripts/gog-sign-in.sh` (the `gog-dev` tool in `GOGKit`). The tool prints the login URL,
the player signs in in any browser and pastes back the address they land on (or just the code).
Anything that refreshes the session must write the new refresh token back.

## Step 0 — Spike with a real account

Run `! scripts/gog-sign-in.sh`, then `gog-dev check`. Record each answer in GOG_PROTOCOL.md and
remove its UNCONFIRMED tag.

- [ ] `gog-dev` in `Packages/GOGKit`: `sign-in` (URL, paste, code exchange, save the session) and
  `check` (refresh, library, builds, secure link, info file). `scripts/gog-sign-in.sh`.
- [ ] Redirect address: does `/token` accept a code issued for another `redirect_uri`
  (`http://127.0.0.1:<port>/`, a `playden://` scheme)? The answer decides whether the relay page
  needs the paste step (PRD 10 decision 2).
- [ ] Token lifetime (`expires_in`) and whether refresh rotates the refresh token.
- [ ] Secure link: the `url_format` placeholders and `parameters`, how long a link lasts (fetch,
  wait, retry), and the answer for a product the account does not own.
- [ ] Library: `embed.gog.com/user/data/games` against the paged `galaxy-library` list. Count the
  games, DLC and hidden items that gamesdb reports.
- [ ] macOS: on one gen 2 and one gen 1 Mac game, what `playTasks[].path` points to, whether
  `codesign --verify --strict` passes on the downloaded bundle, and whether it launches. For gen 1,
  whether to run the wrapper bundle or the inner `.app`.
- [ ] The relay: the macOS prompts (local network, firewall) the first time an `NWListener` serves
  a phone on the LAN.
- [ ] Pick the acceptance games from the account: a gen 2 Windows game with no dependencies, a
  gen 1 Windows game, a native Mac game, a DOSBox or ScummVM game. Avoid Galaxy SDK multiplayer.

## Step 1 — Docs

- [x] `docs/prd/10-gog.md`, `docs/GOG_PROTOCOL.md`, this plan.
- [x] PRD README row. 08 §11 GOG row and FR-V3-3 point to PRD 10. IMPLEMENTATION_PLAN M9.
- [x] `THIRD_PARTY_NOTICES.md`: gogdl (GPL-3) at `9c593fdba2a3e829a48e45e6475d8db937833dce`.
- [x] `.gitignore`: `.gog-session.json`.

## Step 2 — `GOGCore` parsers (`Packages/GOGKit`)

- [ ] `Package.swift` with the `GOGCore` library, `GOGCoreTests` and `gog-dev`. Link `libz`.
- [ ] `GOGCodec`: zlib inflate (header required), MD5, the `galaxy_path` helper (`ab/cd/abcd…`).
- [ ] `GOGBuilds`: the builds list (both generations, `urls[]`, `branch`), and choosing the first
  default-branch build.
- [ ] `GOGManifestV2`: the build manifest (depots, `products`, `dependencies`, `installDirectory`,
  `osBitness`) and depot manifests (`DepotFile`, `DepotDirectory`, `DepotLink`, flags). Paths
  normalized. `sfcRef` parsed and ignored.
- [ ] `GOGManifestV1`: the repository (string sizes, `redist` depots skipped) and depot manifests
  (files, directories, `symlinkType` records without a size).
- [ ] Depot selection: base plus owned DLC, language (`*`, `Neutral`, code, English name), bitness.
- [ ] `GOGInfoFile`: `playTasks`, the primary task, launch options, and the three locations.
- [ ] `GOGDependencies`: the repository manifest, and game-folder entries (empty executable path).
- [ ] Fixtures: a public product's build and depot manifests, and one small chunk from the public
  dependency store. Synthetic gen 1 and gen 2 manifests built in the tests.
- [ ] `scripts/test.sh` runs `swift test --package-path Packages/GOGKit`.

## Step 3 — `GOGCore` API

- [ ] `GOGClientConfig` (client ID and secret, hosts, user agent) and `GOGHTTP` (bearer auth,
  GOG error JSON → `GOGError`, 429/5xx backoff, timeouts that let IPv6 fall back).
- [ ] `GOGAuth`: the login URL, reading the code from a redirect address or a bare code, the code
  exchange, refresh with a 10-minute margin, and saving the rotated refresh token.
- [ ] `GOGLibraryAPI`: owned IDs, gamesdb with ETag, the v2 products API logo, the user's name.
- [ ] `GOGContentAPI`: builds, build and depot manifests from the CDN list, secure links per
  product (gen 2) and per depot path (gen 1), and the dependency `open_link`.
- [ ] Tests with `URLProtocol` stubs.
- [ ] Live tests gated on `GOG_LIVE=1`: download and verify a public dependency depot (no account);
  refresh `.gog-session.json`, list the library, resolve a build and fetch a secure link.

## Step 4 — `GOGCore` downloads

- [ ] `GOGDownloadPlan`: files from the chosen depots in order, chunk use counts, sizes, and the
  game-folder dependency depots.
- [ ] `GOGDownloader` for gen 2:
  - parallel chunk fetches over the CDN list, with retry and backoff;
  - a secure link fetched again on a 401 or 403;
  - both MD5 checks per chunk, then the file's `md5` or `sha256`;
  - shared chunks kept in `.gog-download/chunks` until their last use;
  - a resume journal in `.gog-download/resume`;
  - progress callbacks and cancellation;
  - directories, links inside the folder, executable bits, empty files, `support` files;
  - case-insensitive target paths.
- [ ] `GOGDownloader` for gen 1: `main.bin` ranges of at most 10 MiB, the whole-file MD5, symlink
  records, executable bits, the same journal.
- [ ] `invalidFiles(in:)` for both generations (chunk-by-chunk when a gen 2 file has no hash), and
  `repair`, which downloads only those files.
- [ ] Tests against a stub CDN with synthetic chunks and a synthetic `main.bin`.

## Step 5 — Shared plumbing (PlaydenKit + App), Steam and Epic unchanged

- [ ] `SourceID.gog`. `Account.webLogin`. `SourceAuth.webLoginURL`, `redirectMatches` and
  `signIn(withRedirect:)`.
- [ ] `SignInRelay` (`NWListener`, one-time token, one page and one POST, 10-minute limit).
  `NSLocalNetworkUsageDescription`.
- [ ] `AuthenticationScreen.webLogin`.
- [ ] Redactor: GOG codes, access and refresh tokens, `user_id`, signed secure-link queries.
- [ ] Existing tests pass. New tests: the relay on loopback, three account stores, the redactor.

## Step 6 — `GOGSource` (PlaydenKit `Sources`), Windows builds

- [ ] `GOGAccount`: a `SourceAuth` actor with Keychain `<bundle>.gog`, the web-login sign-in,
  refresh before each operation, and error mapping to `SourceFailure`.
- [ ] `GOGSource`: `ownedGames` (owned IDs plus gamesdb, filtered), metadata, artwork, platforms,
  and the gamesdb cache on disk.
- [ ] `GOGInstaller` for Windows: `resolve` (builds → `InstallPlan` with the payload), download,
  verify, repair, the game-folder dependencies, validate (the info file, the exe exists, matched
  case-insensitively), launch options.
- [ ] Register it in `PlaydenApp`. `StoreNames` gets "GOG" and a glyph.
- [ ] Tests mirroring `EpicSourceTests` with a fixture backend. Live install test gated on
  `GOG_LIVE_INSTALL`.

## Step 7 — macOS builds

- [ ] `resolve(platform: .macOS)` with the `osx` builds; the offer falls back to Windows when there
  is no Mac build.
- [ ] Preparation: file modes, the `.app` normalization, and the ad-hoc signature when step 0 shows
  it is needed.
- [ ] Validation: the Mach-O architectures (32-bit only fails with a reason; x86_64 only needs
  Rosetta), and the gen 1 wrapper rule from step 0.
- [ ] Launch through `NativeRunner`. Uninstall deletes the owned folder.
- [ ] Tests with synthetic Mac manifests and a small Mach-O fixture.

## Step 8 — UI

- [ ] The web-login screen: the QR code and relay address (clickable, copyable), the three steps,
  "Sign in on this Mac", the paste field.
- [ ] The relay page (HTML served by `SignInRelay`), readable on a phone.
- [ ] The login window (`WKWebView`, catches the redirect).
- [ ] The Stores row for GOG (Sign in/out, Refresh, last sync or error). The first-run GOG card.
- [ ] App tests. A `signin-web-login` snapshot.

## Step 9 — Acceptance and docs

- [ ] Sign in with the phone relay and with the login window.
- [ ] Install and play from the UI on this Mac: the step 0 games. Playtime recorded.
- [ ] Resume after a crash; verify files after deleting one; start an installed game offline.
- [ ] Controller-only pass on the TV, together with Epic's.
- [ ] README "What you can do" and the current-focus line. Captures.
