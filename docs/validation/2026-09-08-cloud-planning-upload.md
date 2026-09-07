# Cloud save planning and upload transport — 8 September 2026

## Implemented

`CloudSavePaths` maps UFS remote names to relative paths below an ownership-checked game/bottle
root, and maps local saves back to Cloud names. It handles root overrides, root separator variants,
filename patterns and recursion. Traversal, unresolved placeholders, unsupported names and
ambiguous mappings are rejected. Unmapped local files, including A Short Hike's `.mountain_backup`,
are excluded from Cloud transfers. Existing local filename case is preserved for replacement.
No paths are opened or files changed by the mapper itself.

`CloudSyncPlanner` compares SHA-1 and size on both sides against the last successful baseline.
It plans uploads, downloads, local/remote deletions, unchanged files or conflicts. Timestamps do
not select winners. First-sync differences and deletion-versus-edit are conflicts. A changed
installation ID or mapping invalidates deletion inference, so reinstall pulls remote saves rather
than treating an empty new game folder as an instruction to delete them. Local progress requires
explicit account attachment before automatic application; another account cannot reuse a baseline.
Unknown remote paths and forgotten (not explicitly deleted) remote records stop automatic changes.

`SteamCloudUploader` implements the CM upload batch, file preparation, HTTP instructions, file
commit, explicit deletion and blocking batch-completion calls. It checks the actual account and
remote file list, validates staged bytes, and requires a caller-provided durable batch checkpoint
before transferring files. Remote state is rechecked after reservation. Failed transfers report
failure rather than a successful file commit; failed commits do not finish a successful batch.
After completion it fetches and checks the resulting revision and all present file fingerprints.
A failure after remote commit requires reconciliation; the code does not assume remote rollback.

HTTP instructions preserve the requested method and explicit body (including multipart completion
requests), validate byte ranges, bound allocations/responses, and reuse the read adapter's HTTPS,
header and no-redirect behavior. The callback API is the journal boundary; the persistent journal
and coordinator are still to be implemented.

Protocol definitions/provenance are in `Packages/BigScreenKit/Protos/README.md`. The blocking
completion method is defined by [SteamDatabase's Cloud protocol](https://github.com/SteamDatabase/Protobufs/blob/b008ad5896440fabc63852440f695b3569e6647c/steam/steammessages_cloud.steamclient.proto);
HTTP method values follow [Steamworks ISteamHTTP](https://partner.steamgames.com/doc/api/ISteamHTTP#EHTTPMethod).

## Verification and limits

- Full run passed: 115 package XCTest tests, 3 existing integration skips; 5 package Swift Testing
  tests; 55 app tests. `/tmp/bigscreen-cloud-core-all-tests.log`.
- Then preserved the original local filename case when a remote name differs in case. All 10
  planner/mapping tests passed in `/tmp/bigscreen-cloud-planner-tests.log`.
- Six upload protocol tests passed in `/tmp/bigscreen-cloud-uploader-tests.log`: successful batch
  ordering and payload, stale revision, unexpected reservation, failed journal, transfer/commit
  failures, post-commit mismatch, invalid data/deletion preflight, byte ranges and explicit bodies.
- Upload tests use simulated RPC and HTTP boundaries. **No live Cloud uploads or deletions have
  been performed.** The read-only A Short Hike check from 7 September remains the live evidence.
- Live verification must confirm Steam's reservation revision behavior (currently expected to be
  the prior revision plus one), actual transfer instructions and concurrent-client behavior.
  Preflight/final revision checks alone are not proof of server-side serialization.
- Not yet connected to launch/exit or UI. Still required: durable account-scoped sync journal,
  ownership/session lock integration, staged/conflict backups and local replacement, offline
  retries, controller conflict choices, pending-upload handling at uninstall, and a real roundtrip.

The user's local test save and different existing remote A Short Hike save remain untouched.
Local uninstall save retention remains deferred to a future version.
