# Steam installation boundary — 2026-09-07

This prerequisite slice hardens the authenticated connection needed for real install planning.
It does not implement the durable install orchestrator or complete the install/play acceptance gate.

## Dependency changes

Sibling SteamCore commit **`4d5a46e`** adds:

- Independent deadlines and cancellation for logon, multipart jobs and license-list waiters.
  Default request timeout is 30 seconds. Disconnect completes every pending continuation.
- Connection generations prevent an old receive loop, failed login or late reply from modifying
  a replacement connection. License state and session identity reset on disconnect.
- Multiple callers may await the license list without replacing one another's continuation.
  Multipart responses have a 64 MiB accumulation limit, and nested frames have a depth limit.
- Heartbeat cancellation stops the loop. Network loss is a network error, server logoff is expired
  authentication, and intentional disconnect cancels pending work.
- Injectable depot-key storage. The CLI retains its file adapter; the native account path explicitly
  uses `MemoryDepotKeys` and does not access the CLI depot-key file.
- Codable PICS app/depot/save metadata and launch entries, including executable, raw arguments,
  working directory, OS/architecture and required DLC. Root-level extended DLC metadata is read,
  retaining the older nested-fixture fallback. OS matching uses exact comma-separated tokens.

Steamworks documents platform-specific launch options, executable paths relative to the installation,
arguments and DLC-gated launch options in its [uploading guide](https://partner.steamgames.com/doc/sdk/uploading?l=english&language=english).
The parser preserves metadata; it does not execute raw argument strings or choose an ambiguous
launch option. Source-side launch resolution and argument parsing remain required.

## Native source boundary

`SteamAccount.authenticatedOperation` keeps credentials inside Sources and ties work to the account
generation. Sign-out/replacement cancels registered operations; caller cancellation stops its own
operation while retaining the signed-in account. Renewal is included in the cancellable operation.
Results and renewed credentials are checked against the generation before use or persistence.

`withCM` connects, logs on with the account's refresh token, waits for licenses and disconnects on
success or failure. Its depot keys are memory-only. A rejected CM refresh token maps to expired
authentication. The installer will use this boundary; it is not connected to an Install button yet.

## Evidence

- Targeted SteamCore suite: **36 passed, 2 optional probes skipped**. New cases cover deadlines,
  cancellation, concurrent license waiters, disconnect, stale replies across reconnect, multipart
  completion, network loss, expired auth, PICS launch parsing/round-trip and exact OS matching.
- Explicit live unauthenticated CM probe: **passed in 0.291 seconds**. It connects and sends the
  protocol hello, then disconnects. This is not an authenticated license or depot-download proof.
- `./scripts/test.sh`: **73 passed, 2 optional probes skipped** (36 XCTest package cases including
  two skips, 5 Swift Testing focus cases, 34 app cases). Added source tests cover cancellation on
  sign-out, caller cancellation without logout, and signed-out rejection without CLI fallback.
- Xcode Debug build and deep strict signature verification pass. No visual changes in this slice.

Reproduce the live hello only:

```sh
BIGSCREEN_CM_NETWORK_PROBE=1 swift test --package-path ../GameNative-macos/swift \
  --filter CMRequestTests.testLiveCMHelloWhenRequested
```

Still required: the GameSource installer factory and neutral installer contract, owned DLC resolution
from licenses/packages, pinned manifest plan persistence, aggregate job execution, staging/Steamless,
runner/session integration and the real install/play/save/reinstall acceptance journey. Public store
metadata still supplements library display; this slice does not claim full PICS metadata integration.
