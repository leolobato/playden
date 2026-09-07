# Steam Cloud list and download validation — 7 September 2026

Implemented the read side of the Steam Cloud adapter using authenticated CM unified-service
requests (`Cloud.GetAppFileChangelist#1` and `Cloud.ClientFileDownload#1`). Credentials remain
inside Sources; downloaded bytes are associated with an opaque account key and checked against
the selected remote SHA-1/size. Signing out cancels operations, and another account cannot reuse
an earlier account's file list for downloading.

Remote names remain opaque until a save mapping resolves them. This adapter never writes a game
save, uploads, deletes a remote file, or advances a local sync baseline. It supports full lists,
prefix indices, deleted/forgotten states, raw downloads and one-entry ZIP downloads. Transfers are
HTTPS, ephemeral, bounded to 64 MiB per file, and do not forward signed headers over redirects.
Larger or encrypted files report unsupported transfer errors. ZIP offsets, expanded sizes and
stream completion are checked before returning bytes; archive filenames never become disk paths.

Protocol provenance and regeneration are in `Packages/BigScreenKit/Protos/README.md`. The selected
wire messages come from [SteamDatabase/Protobufs](https://github.com/SteamDatabase/Protobufs/blob/b008ad5896440fabc63852440f695b3569e6647c/steam/steammessages_cloud.steamclient.proto).
Android reference: sibling `GameNative-android`, `SteamAutoCloud.kt`.

## Verification

- The full package/app run passed: 99 package XCTest tests (3 existing integration skips),
  5 package Swift Testing tests, and 52 app tests. Log: `/tmp/bigscreen-cloud-all-tests.log`.
- Then strengthened ZIP decoding to require actual end-of-stream and tested empty compressed
  saves. All 7 Cloud reader tests passed in `/tmp/bigscreen-cloud-reader-tests.log`.
- Tests cover independent protobuf wire bytes, complete/delta/malformed lists, absent and invalid
  prefix indices, case collisions, deletion states, account-key separation, changed hashes,
  cross-game responses, oversized/encrypted transfers, malformed URLs/headers, partial/corrupt
  downloads, compressed payloads, every truncated prefix of a ZIP fixture and hostile offsets.
- Signed app read check used the existing Steam login and A Short Hike (1055540). It retrieved one
  present file, no deleted/forgotten files, revision 1. The file was
  `%WinAppDataLocalLow%adamgryu/A Short Hike/GameSaveNew.mountain`, 29,454 bytes, and its SHA-1
  matched Steam's declaration. A second full file-list request was identical.
- Diagnostic artifacts remain in the private app data directory:
  `~/Library/Application Support/Big Screen/Diagnostics/cloud-read-A3E5B52E-C0C4-4295-9833-1BD905965BA1/`.
  `report.json` records the result and SHA-256; `download-0.bin` is the diagnostic copy.
- The initial diagnostic run hit Foundation's assertion against combining atomic write and
  without-overwriting options. Fixed the developer check to use exclusive creation in its unique
  output directory, rebuilt and reran successfully. This did not touch game files or remote data.

The debug-only command is `./scripts/run.sh --cloud-read-check 1055540` after rebuilding. It uses
normal shutdown rules and exits after the check. Open Big Screen normally afterwards.

## Still required for v1

This is **not completed Cloud sync**. The local A Short Hike test save is 9,641 bytes and differs
from the remote save. Neither may silently replace the other. Remaining work includes the durable
account-scoped baseline/journal, local path resolution and transactional replacement, upload
batches, conflict UI, pre-launch/post-exit orchestration, pending-upload retry/discard handling at
uninstall, and the end-to-end Cloud roundtrip/controller acceptance run.

Local uninstall retention was explicitly deferred by the user; there is no v1 Keep saves option.
