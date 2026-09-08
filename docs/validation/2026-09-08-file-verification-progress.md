# File verification progress — 8 September 2026

The apparent stall at 30% was a whole-file hash check of the completed 19,578,826,238-byte
`Game/Data0.bdt` archive. A live process sample showed `ChunkCheckpointWriter.finish` calling
`ResumableDepotDownload.isValid`, mostly inside disk reads. The read position advanced from
11,598,299,136 to 11,806,965,760 bytes in five seconds. The old row continued to say Downloading.

The downloader now reports file-local verification counters at the start/end and up to four
times per second during reads. The download row shows Verifying file, a file-level percentage,
bytes checked and the filename. Speed/ETA are hidden, with fresh rate windows when downloading
resumes. Existing complete files also report their read checks. Downloaded/written counters
remain separate; the durable install stage is unchanged. Ordered Steam event sequence numbers
prevent delayed download callbacks from replacing a newer verification state.

Validation:

- 13 SteamKit resume/download tests passed, including verification counters for newly written
  and reused files, checksum failures, interrupted downloads and corrupt checkpoint recovery.
- BigScreenKit: 257 XCTest tests passed (6 existing integration skips) and 5 Swift Testing
  tests passed. A subsequent focused queue run passed 16 tests, including the added check for
  delayed events, verification snapshots and clearing verification on pause.
- 13 focused app tests passed, covering verification labels/progress, hidden speed/ETA,
  returning to download progress and existing install interactions.
- Reviewed `.build/verification-review/install-verifying.png`: file percentage and checked
  bytes fit the fixed layout, with speed and ETA hidden.
- Debug and Release builds passed, including strict code-signature verification.

The running interactive app and download were not restarted or replaced.

## Resume-check follow-up

The later zero-speed report was a separate path: `ChunkCheckpointWriter.restore` was reading
and validating saved chunks in the 9,785,030,483-byte `Data1.bdt` partial. That path did not
report progress, leaving the preceding file's name and download speed visible. It now reports
checked bytes against the saved ranges, while only valid chunks contribute to retained bytes.
Saved chunks are read in offset order and buffers are released after each read. The mini
panel, game-details panel and tile also use verification status and percentage.

All 14 SteamKit download/resume tests passed, including the new case with corrupted saved
chunks: every saved range is checked, only valid chunks are retained, and refetched bytes
remain separate. The two focused download presentation tests also passed.
The Release build and strict code-signature verification passed.
