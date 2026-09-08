# Download failure at a depot boundary — 8 September 2026

The saved Armored Core VI job failed with 64,859,467,399 assembled bytes, exactly the total
for depot 1888161, with its last file `Game/steam_input_manifest.vdf`. The second selected
depot, 1888164, contains 111,413,272 bytes. Only the generic SourceFailure text survived in
the job and diagnostic log: "The store returned an incomplete library."

The downloader previously requested each depot key just before that depot began. The first
depot took roughly 49 minutes in this invocation; a closed CM would make the second key
request throw `protocolError("not connected")`, which mapped to the library-import message.
This matches the saved boundary and error category, but the original protocol detail was
discarded, so the specific historical connection loss cannot be proven from the saved log.

A read-only live diagnostic accepted the stored sign-in, verified ownership, and fetched
both entitled depot manifests successfully. No installation files were written by that check.

The backend now fetches every selected depot key into its invocation-local memory store
after checking entitlement, then disconnects CM before the CDN transfer. Missing connections
produce a network error. Generic malformed-response text no longer claims a library import.

Validation:

- CM request tests: 11 tests, 1 existing live-network skip, no failures. The new regression
  obtains two depot keys through a fake transport, disconnects it, then downloads two empty
  pinned manifests using cached keys. A missing third key reports network connection loss.
- Steam account tests: 12 tests, 1 existing skip, no failures, including cancellation/sign-out.
- Release build and strict signature verification passed. A bounded live probe closed CM
  before transferring real CDN chunks, then wrote and verified 7,344,304 bytes on `/Volumes/VM`.
  Its temporary directory was removed; the existing installation was untouched.

Recovery: replace the app with the updated Release build and choose Retry for the failed job.
Existing files/checkpoints are rechecked and retained. Cancelling the job is unnecessary.
