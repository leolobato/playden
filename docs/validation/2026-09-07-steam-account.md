# Steam account and native UI validation — 2026-09-07

Environment: Apple Silicon Mac17,9, macOS 26.6.2, Xcode 26.3 / Swift 6.
Required sibling `GameNative-macos` change: `8da61ce`, injected auth credential persistence and
strict owned-library response parsing. No real account was approved during these checks.

## Automated checks

- `./scripts/test.sh`: 24 app tests and 22 package tests passed. One additional, opt-in network
  test was skipped by the ordinary suite and then run separately below. The app tests cover keyboard/
  controller action routing, tab/modal trapping, focus-driven grid and Downloads scrolling in both
  directions, editing/persistence, masked credential entry and focus retention during live refresh.
- Package tests include actual Keychain round trips in unique disposable services, logout during
  delayed token renewal, canceled sign-in, metadata mapping, source-neutral progressive refresh,
  cached-library preservation on failure and local edits surviving refresh/logout.
- `BIGSCREEN_STEAM_NETWORK_PROBE=1 swift test --package-path Packages/BigScreenKit --filter
  SteamAccountTests.testLiveQRChallengeAndPublicMetadataWhenRequested`: passed. Steam issued an HTTPS
  QR challenge; the test canceled the attempt and verified no credentials were saved. Public Cuphead
  metadata returned a description and genres. The challenge URL was never logged or captured.
- The sibling's three auth-storage/parser tests passed when that change was introduced. They cover
  injected renewal storage, persistence failure and malformed library responses preserving the cache.

## Native rendering and input

`BIGSCREEN_SNAPSHOT_DIR="$PWD/.build/auth-ui" ./scripts/snapshot.sh --snapshot-width 1280`
captured 16 native screens. Home, Library, QR sign-in, credentials and network-error screens were
visually inspected. The sign-in capture uses `https://example.invalid/big-screen-design-preview`;
it is a layout fixture and cannot authenticate an account. The later credential-copy/header-spacing
adjustments were checked in the actual running app.

The live app was launched through Launch Services with `--windowed`. Its Home and Library showed
an empty catalog and sign-in actions, with no sample games or queue injected. Targeted keyboard
events opened sign-in, switched to password, opened the account-name keyboard, canceled back to
the app, and switched to Library with Tab. Accessibility labels confirmed the credentials screen
and keyboard before capturing the empty credential form. No password was entered or submitted.
The window title/product name is Big Screen. DS4 foreground input was confirmed earlier by the
user; the new sign-in flow has action-level tests and keyboard verification, not a new DS4 hardware run.

## Runtime packaging

`./scripts/build.sh` passed. `codesign --verify --deep --strict` passed on the built app. `otool -L`
confirmed that the app's debug library resolves liblzma and libzstd through `@rpath` in the app's
Frameworks directory. Those two libraries depend only on macOS's libSystem. The SteamCore resource
bundle, including both emulator DLL resources and provenance, is present. Compression-library
license texts are copied into Resources/Licenses by the embed step.
The embed outputs are declared to Xcode so incremental builds sign changed resources. The build
script now verifies the final signature; this caught and resolved a skipped-signing issue when
license resources were first added. A subsequent unchanged incremental build also passed.

The deployment target is macOS 15, matching the minimum of the available compression binaries.
This does not establish execution on macOS 15; the machine used here runs macOS 26.6.2.

## Integration behavior and remaining acceptance

Live data uses `Application Support/Big Screen/catalog.sqlite`. The preview uses the separate
`Big Screen/Preview` directory. Authentication tokens use Keychain service
`com.gamenative.bigscreen.steam`, account `current`; there is no file fallback. Passwords and Guard
drafts stay in memory and are cleared after submission/cancellation. No credentials or account
identity are serialized into the catalog. Logout retains local edits and installation records.

Owned games come through SteamCore. Optional genres, description and controller support come from
Steam's public store `api/appdetails` endpoint, with an ephemeral session, no cookie/cache storage,
bounded concurrency of two, request pacing and a six-hour metadata TTL. Unknown controller support
stays unknown. This endpoint is optional and its availability is not an ownership or launch guarantee.
Network/throttle failures stop enrichment while retaining the already committed owned library;
later startup/manual/scheduled refresh can continue it. Exponential retry/backoff remains pending.

Real QR approval, password/Guard submission, 600-title account refresh, authenticated offline
restart and full first-run timing still require acceptance evidence. Installer/runner/session
integration, volume/template setup and background controller exit routing remain unfinished.
These checks establish the account/catalog UI slice; they do not satisfy the v1 gameplay gate.
