# Install plans and live library recovery — 2026-09-07

## Live account issue

The user completed Steam sign-in but saw no games. Read-only inspection found zero source games
and the app's Keychain failure message; this was before the owned-games request completed.
Restarting the rebuilt app recovered the existing saved sign-in without logging out or asking for
another Steam approval. The database then held **538 games**. A second restart refreshed the same
538 games. Native window inspection confirmed the real library and artwork render.

The running app had been launched directly from DerivedData while ongoing Xcode builds/tests
replaced and signed that bundle. That is the likely trigger; the original build discarded the
OSStatus, so the precise initial Keychain failure code was not captured. Credential errors now retain
the numeric macOS code and emit only that code to the `com.gamenative.bigscreen` / `Keychain` log.
No account identity, QR, credential, or request URL is written by this diagnostic.

`scripts/run.sh` now verifies and launches a copy under `.build/Run`, separate from build output.
It asks the previous instance to quit normally before replacing its bundle, and fails if it remains
running. A full Xcode test/build ran while that copy stayed open; its signature remained valid.
Refreshing through Settings afterward completed successfully: 538 games, a new sync timestamp,
and no Keychain error. The user can continue browsing while builds run.

### Follow-up: stable identity across different builds

After a subsequent code change, macOS displayed its own Keychain prompt for
`com.gamenative.bigscreen.steam`. This exposed a second development issue: ad-hoc signing
does not give successive binaries a stable identity. Isolating the running copy protects it
from in-place replacement, but does not itself preserve trust across changed binaries.

Build/test scripts now select an existing Apple Development certificate and cache the selected
fingerprint locally under `.build/signing-identity`. They never create/import certificates or
change Keychain item access controls. An environment override is supported; machines without
a development certificate retain an explicit ad-hoc fallback. The certificate-based build and
the full 83-pass/2-skip test run succeeded. The app's designated requirement remains compatible
across build/test packaging changes. Existing ad-hoc credentials require a one-time native
Keychain approval when moving to this signing identity; only the user enters the Mac password
into that macOS dialog. End-to-end approval/rebuild persistence remains to be observed afterward.

Apple's [code-signing requirements note](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
explains how macOS recognizes successive versions through their designated requirement;
[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) describes its use
for Keychain access.

## Source installer boundary

Domain now defines `Installer`, immutable/versioned `InstallPlan`, estimates, progress, staging
mutation receipts and original-file verification. Sources provides the Steam factory. Jobs and
installations can persist the pinned plan; installations can also persist staging receipts. Older
records without these optional fields still decode.

Steam resolves active account licenses into package app/depot entitlements. Advertised DLC is never
used as ownership evidence. It selects Windows/English content and owned DLC, pins manifest IDs,
validates paths/chunk ranges and cross-depot collisions before storage, rejects conflicting shared
files, and avoids counting/downloading identical shared files twice. Storage estimates include
retained-original and temporary assembly allowance. Ambiguous Windows launch configurations require
a recipe; executable/working-directory paths come from metadata and are checked against manifests.
Arguments become literal argv values using Windows quoting rules, without shell expansion.

Saved plans are rebuilt and compared before use, so duplicate depot IDs, altered launch paths,
inconsistent estimates and unsupported payload versions fail without integer/dictionary traps.
Download uses the pinned manifests, rechecks ownership and keeps credentials/CM connections inside
Sources. Verification maps transformed Steam DLLs to verified `.orig` files. Offline preparation uses
synthetic identity and owned DLC with `unlock_all=0`. Interrupted preparation can retry using backups
only after those backups verify against the pinned manifest. Staged DLL hashes are checked separately.

SteamStub is detected before mutation and reported as an incomplete preparation requirement.
Steamless integration, title recipes/prerequisites, durable queue/orchestration, per-game bottles,
real download/repair, launch supervision and save/reinstall remain open. These fixture checks do
not establish that any real game is installed or playable. The live Install action remains explicit
about the missing orchestration; it does not turn a resolved plan into an installed record.

## Evidence

- `./scripts/test.sh`: 45 package XCTest cases (2 optional live probes skipped), 5 focus tests,
  and 35 app tests; **83 passed, 2 skipped**, no failures.
- New source fixtures cover depot/owned-DLC selection, missing manifests, conflicting paths,
  launch ambiguity/casing, Windows quoting, corrupt plans, actual chunk download to temporary files,
  bundled GBE staging/retry, original vs replacement damage, and SteamStub preflight.
- Catalog tests cover plan/receipt persistence across SQLite reopen and old-record decoding.
- App regression exercises successful sign-in → immediate owned-library presentation.
- Upstream SteamCore suite: **39 passed, 2 optional probes skipped**; package binary KV, active/owned
  license flags, truncation, duplicate keys and identity checks are included.
- App build and deep/strict signature verification passed; running copy remained valid after tests.
- Required sibling commit: `0661a04` in `GameNative-macos` (scoped SteamCore changes only).

Protocol references: SteamKit's [license and PICS callbacks](https://github.com/SteamRE/SteamKit/blob/master/SteamKit2/SteamKit2/Steam/Handlers/SteamApps/Callbacks.cs)
describe package metadata and its binary KeyValues buffer; [Steam license flags](https://github.com/SteamRE/SteamKit/blob/master/Resources/SteamLanguage/enums.steamd)
identify inactive/borrowed license states. Microsoft's [argument parsing rules](https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments)
describe the literal Windows argv conversion. Apple's [Mac keychain implementations note](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
is the reference for the macOS storage API distinction.
