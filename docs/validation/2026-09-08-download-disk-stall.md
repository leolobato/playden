# Large download disk stall — 8 September 2026

Armored Core VI (1888160) stayed at zero written bytes while downloading `Game/Data0.bdt`.
The live job had reached the download stage. A process sample showed the worker inside
`ChunkCheckpointWriter.commit` → `DownloadWorkspace.sync` → `fcntl(F_FULLFSYNC)` throughout
the sample. The open partial file was already 19,578,826,238 bytes long, with the entire size
allocated on the USB, Journaled HFS+ VM volume. No journal had been published yet.

The writer grew each partial to its full final length before receiving content and forced a
drive-cache flush after every chunk and journal write. The first chunk reached the writer but
could not return progress while that flush was blocked. This was a disk-write stall, distinct
from the previously fixed Steam entitlement error.

Changes:

- Partial files grow as chunks arrive; a short partial is valid for checkpoint recovery.
  Unmatched checkpoints reset the partial instead of preallocating the final archive size.
- Missing chunks are scheduled by file offset, preserving original journal indices and
  limiting holes caused by concurrent, out-of-order completions.
- The writer checkpoints after 16 MiB or one second of received chunks, and on orderly
  pause/error or file completion. Data is synced before the journal is atomically replaced.
- Download sync uses ordinary file synchronization without `F_FULLFSYNC`. Resume still
  validates every retained chunk; abrupt termination may redownload the pending batch.
- `--diagnose-install APP_ID --download-probe-root FOLDER` optionally exercises the actual
  CDN/downloader/disk path with at most eight chunks and 8 MiB uncompressed, in an isolated
  temporary directory that is removed when the probe exits.

Validation:

- 12 SteamKit download tests passed, including pause/resume, corruption, whole-file hash
  failure, path/lease checks, reversed chunk ordering, and a 20 GB manifest that writes only
  one megabyte before interruption and correctly resumes that short partial.
- BigScreenKit: 250 XCTest tests, 6 existing integration skips, no failures; 5 Swift Testing
  tests passed.
- Signed Release build and strict signature verification passed.
- Live Release probe on `/Volumes/VM`: Steam authentication and both entitled manifests
  succeeded; 7,344,304 bytes of real game chunks were downloaded, written, reread and verified.
  Exit status 0, 6.6 seconds including metadata resolution; probe directory cleaned up.

The existing installation was not modified by the probe, and the installed app was not
replaced. This is a bounded download/write check, not a completed installation or gameplay test.
