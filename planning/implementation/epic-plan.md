# Epic Games Store — commit plan

Requirements: [PRD 09](../../docs/prd/09-epic.md). Protocol: [EPIC_PROTOCOL.md](../../docs/EPIC_PROTOCOL.md).
Branch: `epic`. Commit each step once it builds and its tests pass. Mark steps done here and
commit this file with them.

Live testing uses `.epic-session.json` in the repo root (gitignored). It holds a launcher session
from the step 0 spike. Anything that refreshes it must write the new refresh token back.

## Step 0 — Auth spike

- [ ] Switch device code → exchange code → launcher `exchange_code` grant, with a real account.
- [ ] The launcher token lists the assets and the library, creates a launch exchange code, and
  refreshes.

## Step 1 — Docs

- [x] `docs/prd/09-epic.md`, `docs/EPIC_PROTOCOL.md`, this plan.
- [x] PRD README row. 08 §11 Epic row and FR-V3-4 point to PRD 09. IMPLEMENTATION_PLAN M8.
- [x] `THIRD_PARTY_NOTICES.md`: legendary (GPL-3) at `42f6bdeadde3a9526dc8eb713763476999ac217b`.

## Step 2 — `EpicCore` parsers (`Packages/EpicKit`)

- [x] `Package.swift` with the `EpicCore` library and `EpicCoreTests`. Link `libz` (`linkedLibrary("z")`)
  for zlib streams, and use CryptoKit for AES-GCM.
- [x] `BinaryReader` (LE ints, FString ASCII/UTF-16, GUID).
- [x] `Manifest`: the header and zlib body with a SHA-1 check, then Meta, CDL, FML and CustomFields.
  Each section seeks to its end by its size. v22+ adds secret GUIDs and encrypted data. `build_id`
  is computed when absent.
- [x] `JSONManifest` with blob decoding. It converts to the same `Manifest` model.
- [x] `Chunk`: the header (v1–v4), zlib and AES-GCM decoding, and the SHA-1 check against the CDL.
- [x] `ChunkInfo.path` for every chunk-dir version and for v22+ base64url paths.
- [x] Fixtures: `overlay.manifest` and one overlay chunk (the public EOS Overlay app). Synthetic
  manifests built in the tests cover compressed, JSON and encrypted.
- [x] `scripts/test.sh` runs `swift test --package-path Packages/EpicKit`.

## Step 3 — `EpicCore` API

- [x] `EpicClientConfig` (client IDs and secrets, user agent), `EpicHTTP` (UA, basic and bearer
  auth, Epic error JSON → `EpicError`, 429/5xx backoff).
- [x] `EpicAuth`:
  - the device-code flow: Switch client credentials, device authorization, polling, exchange,
    launcher redeem, and killing the Switch session;
  - refresh, verify and kill;
  - `exchangeCode()`;
  - `corrective_action_required` handling.
- [x] `EpicLibraryAPI`: assets per platform, library items with a cursor, catalog bulk items, the
  manifest API (elements, manifests plus query params, `secrets`, sidecar) and the ownership token.
- [x] Tests with `URLProtocol` stubs.
- [ ] A live test gated on `EPIC_LIVE=1` reads `.epic-session.json`, lists the assets and fetches
  one manifest.

## Step 4 — `EpicCore` downloads

- [ ] `DownloadPlan`: the unique chunks in first-use order, a reference count per chunk, file
  parts, and the sizes (download = Σ compressed chunk sizes, installed = Σ file sizes).
- [ ] `EpicDownloader`:
  - parallel chunk fetches over the base URLs with retry and backoff;
  - a bounded cache of decoded chunks, spilling to `.epic-download/chunks` when a chunk is still
    referenced;
  - writing files in order;
  - progress callbacks;
  - cancellation;
  - a resume journal in `.epic-download/resume` (`sha1:path`);
  - symlinks, executable bits and empty files;
  - case-insensitive target paths.
- [ ] `verify(install:manifest:)` → missing and mismatched files. `repair` downloads only those
  files.
- [ ] Tests against a stub CDN with synthetic chunks.

## Step 5 — Shared plumbing (PlaydenKit + App), Steam unchanged

- [ ] `SourceID.epic`. `Account.deviceCode`. `SourceAuth.signInWithDeviceCode`.
  `AuthenticationEvent.deviceCode`.
- [ ] `Installer.prepareLaunch` and `Installer.launchAvailability`, called from
  `SessionService.launchTracked`. The Play gate goes in `LibraryModel` / `detailActionEnabled`.
- [ ] Per-source account state in `LibraryModel`/`AccountModel`. The source ID is carried by
  `recordSyncFailure`, `SessionRecovery`, `installOfferRequiresSignIn` and the queue's auth pause.
- [ ] One `LibrarySyncCoordinator` per remote source.
- [ ] `InstallQueue`/`SessionService` exist without Steam. First run's drive and runtime gate
  checks any signed-in download store.
- [ ] Redactor: exchange codes, `-epicuserid=`, Epic refresh tokens.
- [ ] `coverFallbackURL` returns nil for non-Steam games.
- [ ] Existing tests pass. New tests: two account stores, source-scoped recovery, prepareLaunch
  and the offline gate.

## Step 6 — `EpicSource` (PlaydenKit `Sources`)

- [ ] `EpicAccount`: a `SourceAuth` actor with Keychain `<bundle>.epic`, the device-code sign-in,
  refresh before each operation, and error mapping to `SourceFailure`.
- [ ] `EpicSource`: `ownedGames` (assets plus catalog, filtered), `metadata`, artwork, store
  page (`store.epicgames.com`), and `downloadSize`.
- [ ] `EpicInstaller`: `resolve` (manifest API → `InstallPlan` with the payload), download, verify,
  repair, validate (the exe exists, PE check), `prepareLaunch` (exchange code, ovt, arguments), and
  `launchAvailability`.
- [ ] Register it in `PlaydenApp`. `StoreNames` gets "Epic" and a glyph.
- [ ] Tests mirroring `SteamInstallerTests` with a fixture backend.

## Step 7 — UI

- [ ] The device-code sign-in screen: code, URL, QR, countdown, the Fortnite note, a new code on
  expiry.
- [ ] The Stores row for Epic (Sign in/out, Refresh, last sync or error). The first-run Epic card.
- [ ] The game page: "Needs the EA app / Ubisoft Connect", the offline block reason, and the
  anti-cheat notice.
- [ ] App tests.

## Step 8 — Acceptance and docs

- [ ] Run the PRD 09 §6 manual acceptance on the TV.
- [ ] README "What you can do" and the current-focus line. Captures.
