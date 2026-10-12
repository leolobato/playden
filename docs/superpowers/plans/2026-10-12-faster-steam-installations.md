# Faster Steam Installations Implementation Plan

**Status:** Steps 0–11 implemented and validated on 2026-10-12. Required package and app suites passed; measurements and
requirement evidence are recorded in [the final results](2026-10-12-faster-steam-installations-results.md). Final whole-branch
review approved revision `2ba75aa` with no Critical or Important findings; the two Minor test findings and focused cleanup
are recorded in the results. The cost descriptions below record the original baseline, before implementation. Follow-up
steps 12–15 (lessons from Playden for PS5) are planned and not started.

**Goal:** Remove redundant disk reads, hashing, flushes and oversized space reservations. Keep reliable downloads, pause/resume,
preparation and explicit repair.

**Branch:** `feat/improve-installs`, in the worktree
`/Users/leolobato/.chauffeur/worktrees/D5566080-ECFD-577E-C3A5-16A5849E44F4/feat-improve-installs`. Work and commit on this branch.
Commit each completed step separately.

**Scope:** Steam Windows and native Mac installations. Other stores keep their current behavior. Step 0 is a queue robustness fix
found during a live download; it applies to every store.

**Architecture:** Downloading, preparation and repair are distinct operations. A fresh installation trusts validated incoming
chunks and successful writes. Ordinary resume and the existing stage checks use completion receipts and file metadata. Explicit
**Verify files** (repair) does full content verification.

**Accepted tradeoff:** A normal installation no longer rereads every written byte. Metadata-based checks can miss corruption that
keeps the recorded size and timestamps. Explicit verification remains the way to find it. Files without a whole-file SHA-1 in
the manifest are verified only by per-chunk Adler-32, which is the same check used while downloading.

## Current costs (verified in the code)

- **Connections:** each chunk request creates and invalidates a new ephemeral `URLSession` (`CDN.swift:194-198`). That is one TLS
  handshake per ~1 MiB chunk.
- **Chunk checks:** each chunk is validated three times (`CDN.swift:185`, `ResumableDepotDownload.swift:55`, `:269`). The journal
  also stores a SHA-256 of each chunk (`:271`).
- **Adler-32:** `DepotManifest.Chunk.adler` (`CDN.swift:31-35`) loops byte by byte with two `% 65521` per byte. This is likely
  much slower than zlib's `adler32`.
- **Final reread:** `finish()` reads the whole file back (`ResumableDepotDownload.swift:285-286`).
- **Syncs:** checkpoints every 16 MiB or 1 s (`:273`). A checkpoint is a data fsync, a journal fsync and two directory fsyncs.
  `replace()` (`DownloadWorkspace.swift:78-79`) syncs both directories even when they are the same. `finish()` syncs twice
  (`:284`, `:293`) and writes a journal that it deletes immediately after. Many small files pay roughly 8 fsyncs each.
- **Small files:** most small files are one chunk. Files download one after another, so small files transfer one network round
  trip at a time.
- **Whole-game rereads after download:** a fresh install hashes every file three more times: the `.verifyOriginals` stage
  (`InstallQueue.swift:303`), `prepare` (`SteamInstaller.swift:93`) and `validate` (`:193`). Mac does the same at `:448` and `:492`.
- **Repair rereads twice:** `repair()` checks every file (`SteamInstaller.swift:151`), then `backend.download` hashes every existing
  file again (`ResumableDepotDownload.swift:29`).
- **Resume rereads:** resuming a paused download hashes every completed file again (`ResumableDepotDownload.swift:29`).
- **Directory walks:** `rejectLinks` walks the whole game folder at `SteamInstaller.swift:68`, `:86`, `:176`, at `:150` through
  `checkLinks`, and once per executable inside the loop at `:113`.
- **Space estimate:** `2 × installed + largest + 256 MiB` (`SteamInstallPlan.swift:65`). `InstallQueue.swift:282` subtracts
  transfer progress (`bytesCompleted`) from it, which mixes transfer progress with space allocation.
- **Progress callbacks:** one per chunk (`ResumableDepotDownload.swift:64`), each hopping into the `InstallQueue` actor.

## Order

0 → 1 → 2 → measure again → 3, 4, 5 → 6 with 7 → 8 → 9 → 10. Steps 9 and 10 do not depend on 3–8. After step 2, use the measurements
to confirm priorities; do not skip a step without recording why.

## 0. A busy catalog database must not stop the install queue

This was found during a live GTA V Legacy (Steam app 271590) install. **Check first whether `feat/gtav` already has this fix.** If
it does, cherry-pick or merge it rather than writing it twice.

**What happened:** after about 55 minutes (60.4 GB of 127 GB) the job went from `download · running` to `download · queued` at
10:55:13. It had no pause reasons, no failure and no cancel request, and it never restarted.

**Cause:**
- `CatalogStore` (`Packages/PlaydenKit/Sources/Catalog/CatalogStore.swift:19-23`) opens a `DatabaseQueue` with GRDB's default
  `Configuration`. There is no busy timeout, so a write fails immediately with SQLITE_BUSY while another process holds a read lock.
  The live catalog (~357 MB) uses `journal_mode=delete`, where readers block writers.
- An external `sqlite3 -readonly` loop polled the catalog every 30 s during the download.
- When a progress save fails, `InstallQueue.progress` sets `persistenceFailure` and cancels the active task (`InstallQueue.swift:440`
  on this branch). The cancelled download has no pause reason, so it is saved as `.queued` (`:349`).
- `pump()` does not start a job while `persistenceFailure` is set (`:240`). The flag lives only in memory, so the queue stays
  blocked until Playden restarts. The terminal save in `execute`'s catch (`:368`) has the same effect.

**Fix, in this order:**
1. **Busy timeout.** Set a busy timeout on the catalog connection, for example `configuration.busyMode = .timeout(5)`. Use the API
   of the GRDB version this repo pins. Add a PlaydenKit test that holds a read transaction on a second connection and shows that a
   write waits and succeeds.
2. **Progress saves are advisory.** When a download or verification progress save fails, keep the in-memory progress, retry on the
   next update and log the failure. Keep the queue halt only for save failures at real checkpoints: stage completion, reserve,
   commit, and the terminal error, pause and cancel saves. Review the `:368` path too. Add regression tests in the existing
   `InstallQueue` test style.
3. **WAL mode: do not implement.** It changes the persistent file format. Record the tradeoffs in this plan only.
   WAL would let readers coexist with the writer, reducing this kind of contention. It also introduces persistent WAL/SHM
   sidecars, checkpoint management, and extra care when copying, backing up, or inspecting a live catalog; long readers can
   retain WAL pages and grow the journal. Keep the existing delete journal and full synchronous durability. Use the five-second
   busy timeout for short locks and advisory progress saves for longer contention instead.

**Step 0 checkpoint decision:** Verification-stage callbacks already keep their state only in memory and remain ephemeral.
Download callbacks may save advisory progress, but failed saves keep the in-memory record and retry on the next eligible update.
Durable checkpoint and installation-commit failures halt scheduling even if the subsequent terminal-error save succeeds;
terminal error, pause, and cancel saves retain their halt behavior. Logging on failure uses OSLog to avoid writing again to
an already busy catalog.

**Verify:** `swift test --package-path Packages/PlaydenKit`, then the full `./scripts/test.sh`.

**Live recovery (if the GTA V job is still stuck):** rebuild and relaunch with `./scripts/run.sh --windowed`. It asks Playden to quit
normally; do not force-quit Playden or any game. After relaunch, confirm the job resumes: state `running` and `bytesCompleted`
rising from ~60 GB.

**Do not poll `catalog.sqlite` in a loop**, not even read-only, in this or any later step. Use single queries, or query a copy.

## 1. Establish baseline measurements

Files: `SteamInstallBackend.swift`, `ResumableDepotDownload.swift`, `DownloadWorkspace.swift`, `SteamInstaller.swift`, `CDN.swift`.

- [x] Add lightweight counters and timings: network transfer, session creations, Adler-32 and SHA bytes/time (separately),
  content bytes reread, checkpoints, fsyncs (file and directory), directory walks, progress callbacks, preparation and final
  validation.
- [x] Wire counters through `LiveSteamInstallBackend.download` (`SteamInstallBackend.swift:33-66`), which creates a new
  `DownloadEngine` for each depot.
- [x] Keep diagnostics out of the ordinary UI. Never log credentials.
- [x] Record baselines for a large-file fixture and a many-small-files fixture. Measure a real installation separately when one is
  available.

**Acceptance:** before/after results separate network time, hashing, filesystem work and preparation.

## 2. Reuse CDN connections

Files: `CDN.swift`, `DownloadEngine.swift`, `SteamInstallBackend.swift`; add focused transport tests.

- [x] Replace per-request `URLSession` creation with a shared, injectable CDN transport. Create it once per download in
  `LiveSteamInstallBackend` (or hold it statically), not once per depot engine.
- [x] Keep ephemeral configuration, no cookies or cache, request timeouts, cancellation and server failover.
- [x] Set `httpMaximumConnectionsPerHost` to at least the in-flight chunk budget, or confirm that the CDN multiplexes over HTTP/2.
  `ArtworkLoader.swift:176` is the existing shared-session example.
- [x] Cancelling one request must not invalidate other transfers.
- [x] Test session reuse, concurrent requests, cancellation, timeouts and retries.

**Acceptance:** a download reuses one transport across chunks and depots.

## 3. Validate incoming chunks once; simplify resume journals

Files: `CDN.swift`, `DownloadEngine.swift`, `ResumableDepotDownload.swift`, `DownloadResumeTests.swift`.

- [x] Keep one validation inside the chunk-fetch retry (`CDNClient.fetchChunk`), so corrupt responses still retry. Remove the checks
  at `ResumableDepotDownload.swift:55` and `:269`.
- [x] Replace the Adler-32 loop with zlib's `adler32`. First prove with a test vector that `adler32(0, …)` gives the same result as
  Steam's zero-seed variant.
- [x] Keep length, offset, range and write-error checks.
- [x] Replace per-chunk SHA-256 journal entries with completed chunk indices tied to the pinned file manifest.
- [x] When resuming a partial file, validate retained chunks with `chunk.validate` (as `restore` does already).
- [x] Version the journal. Version 1 journals migrate by keeping their chunk indices; `restore` rechecks each retained chunk. Never
  discard usable downloads only because the format is old.
- [x] Test corrupt responses, invalid ranges, damaged retained chunks, changed manifests and version 1 journals.

**Acceptance:** each new chunk gets one content check and no SHA-256.

## 4. Remove the downloader's final content reread

Files: `ResumableDepotDownload.swift`, `DownloadWorkspace.swift`.

- [x] Replace `finish()`'s full-file hash with checks that every expected chunk completed and the file size matches.
- [x] Keep executable permissions, atomic replacement and durability ordering.
- [x] Record completion only after the file is published.
- [x] Test missing chunks, short files, failed writes, failed renames and cancellation during finalization.

**Acceptance:** completing a fresh file reads none of its content back.

## 5. Reduce checkpoints and redundant syncs

Files: `ResumableDepotDownload.swift`, `DownloadWorkspace.swift`.

- [x] Change checkpoint thresholds from **16 MiB / 1 s** to **128 MiB / 5 s**, whichever comes first.
- [x] Checkpoint on orderly pause and cancellation.
- [x] `finish()` syncs the file once (after `fchmod`), renames it, then removes the journal if one exists. It never writes a journal
  it is about to delete.
- [x] `replace()` syncs a directory once when source and destination are the same directory.
- [x] Keep ordering: persist downloaded bytes before a journal claims them.
- [x] Test interruption before and after each persistence boundary with injected failures.

**Acceptance:** fewer flushes and journal rewrites. An interruption can lose recent progress but never counts missing bytes as
complete.

## 6. Add completion receipts

Files: add `DownloadCompletionReceipt.swift`; update `ResumableDepotDownload.swift` and resume tests.

- [x] Store versioned receipts in the game folder under `.gn-download/`, **one receipt file per depot manifest** (not per game
  file). Write it on the checkpoint cadence.
- [x] Each entry binds the relative path, pinned manifest, size, file identity and timestamps.
- [x] Skip hashing completed files whose entry and metadata still match.
- [x] Fully verify a file when its entry is missing, incompatible or mismatched; then refresh its entry or download it again.
- [x] Keep checking retained chunks in incomplete files.
- [x] Remove the leftover `.gn-download/` state that is not needed after the install finishes. It is never cleaned up today, and
  `rejectLinks` and `GamesStorage` both walk it.
- [x] Test changed size or timestamps, replaced files, copied or stale receipts, older installations and filesystems with coarse
  timestamps.

**Acceptance:** ordinary resume does not reread matching completed files.

## 7. Make the existing stage checks cheap

Files: `SteamInstaller.swift`, `ResumableDepotDownload.swift`; installer tests. **Do not change `Domain/Installer.swift` or
`InstallQueue` stages.**

- [x] Make Steam's `verifyOriginals` use the step 6 receipts by default: a file whose metadata matches its receipt is not hashed.
  The `.verifyOriginals` stage, `prepare` and `validate` then cost only metadata lookups.
- [x] Keep the `.verifyOriginals` stage. It stays the restart-safe proof that the download finished: a mismatch still sends the job
  back to download (`InstallQueue.swift:362`).
- [x] Repair uses a full mode that ignores receipts. It checks once, then downloads **only the files that failed** (pass the
  invalid set to the download instead of letting it hash every file again), and refreshes their receipts.
- [x] Backups and prepared files (`.orig`, Mac originals) have no receipts and are hashed as today. These are few files.
- [x] Keep executable compatibility checks, preparation receipts and Mac signing checks.
- [x] Test restart at each stage, interrupted `.orig` creation, damaged backups, Windows executable preparation, Mac signing, and
  unchanged GOG/Epic behavior.

**Acceptance:** a fresh install has no whole-game content rereads. Repair does one full inspection plus targeted checks.

## 8. Replace repeated directory-wide link checks

Files: `SteamInstaller.swift`, `SteamPrerequisites.swift` and preparation helpers that write files.

- [x] List every preparation write destination.
- [x] Replace repeated recursive walks (including the one per executable at `SteamInstaller.swift:113`) with checks of the source,
  destination and parent paths involved.
- [x] Keep destination containment and installation ownership checks.
- [x] Check once per uninterrupted operation; check again after a restart or interruption.
- [x] Keep required Mac framework symlinks and reject write paths that escape the folder.
- [x] Test linked parents, replaced destinations, legitimate Mac links and ownership mismatches.

**Acceptance:** preparation no longer walks unrelated game assets to authorize a few writes.

## 9. Overlap small-file downloads

Files: `ResumableDepotDownload.swift`, `DownloadEngine.swift`, `SteamTransferProgress.swift`; add scheduling tests.

Do this after step 5, and only if measurements still show per-file latency.

- [x] Preferred design: one ordered queue of chunks across all files, with **eight chunks in flight in total**. Each file has its
  own writer and journal and is finished when its last chunk lands. This keeps at most a few files open and removes the small/large
  split.
- [ ] Alternative if that is too large: up to **four files of 16 MiB or less** at a time, sharing the same eight-chunk budget.
  Not selected: the preferred ordered global eight-chunk design was implemented and tested.
- [x] One destination lease for all workers.
- [x] Create symlinks only after all file writes complete.
- [x] Progress stays monotonic. Drain workers before pause or cancellation completes.
- [x] Test concurrency limits, shared directories, failures, cancellation, bounded memory and accurate progress.

**Acceptance:** small files overlap without increasing network concurrency or causing destination races. Compare SSD and
external-drive results before tuning defaults.

## 10. Replace the oversized space estimate

Files: `SteamInstallPlan.swift`, `GamesStorage.swift`, `InstallQueue.swift`; storage and plan tests.

- [x] Remove `2 × installed + largest + 256 MiB`.
- [x] Peak extra space = installed content + backups of files that preparation may change (executables and API DLLs; copies may not
  be clones on HFS+) + **256 MiB**. Download partials count as installed content because they are renamed into place.
- [ ] Repair: old and new content overlap only for the prepared files, because repair downloads originals to their backup paths.
  **Clarification:** this literal assumption is false under retained atomic replacement: invalid ordinary targets also coexist
  with their replacement partials. Preserve the old target until rename and gate the entire invalid subset plus preparation
  backups/headroom, crediting only validated replacement partial allocation and assuming no old extents are reclaimed.
  The implementation and tests prove this conservative behavior; the original wording is retained rather than marked true.
- [x] Keep the reservation separate from transfer progress (`InstallQueue.swift:282`).
- [x] Check the correct volume for game content versus runtime storage.
- [x] Unfinished older jobs keep their stored, larger estimate. That is safe, so do not recalculate them.
- [x] Test fresh installs, resume, repair, multiple queued jobs, low disk space and arithmetic overflow.

**Acceptance:** reservations reflect peak extra allocation, not a second copy of the game.

## 11. Validate the branch

For each step: add a focused regression test, confirm that it fails before the change, implement, run the relevant tests and commit.

Then run the complete suites:

```sh
swift test --package-path Packages/SteamKit
swift test --package-path Packages/PlaydenKit
./scripts/test.sh
```

- [x] Compare baseline and final counters: content rereads, checksum work, syncs, session creations, callbacks and elapsed time.
- [x] Exercise pause/resume, forced termination, network failure, disk-full failure and preparation recovery.
- [x] Confirm that explicit repair still finds and fixes corruption.
- [x] Confirm that displayed progress and reservations match the new behavior.
- [x] Report measured improvements and any workloads that got slower.

## Follow-up: lessons from Playden for PS5

**Status:** Planned; not started.

Playden for PS5 (`/Users/leolobato/Documents/Projetos/Personal/playden/ps5/playden-ps5`, branch `main`) made the same kind of
Steam download work on 2026-10-12: commits `2581f38` (stage measurement), `15ba7d1` (connection and DNS reuse), `0e17808` (several
chunks at once), `9c260cd` (journals bound to manifests), `f4fbd0c`, `8affe33` and `a8cde7b` (speed and time-left labels). Read
those commits for reference. They are C++; do not copy code.

Already covered by steps 0–11, no work needed: connection reuse (`URLSession` also caches DNS), bounded chunk slots with
serialized writes per file (step 9), and journals bound to the pinned manifest (`.gn-download/<depot>/<gid>/` plus the per-file
fingerprint). PS5's Mbed TLS threading change (`ebd0edd`) does not apply.

Order: 12 → 13 → 14. Step 15 is independent and small.

### 12. Record download stats for live installations

Steps 1–11 measured only fixtures. The results say they make **no live CDN throughput claim**, and `SteamPerformanceDiagnostics` is
not enabled for real installs. PS5 records stats for every real run and reports them with `tools/download_speed_report.py`.

Files: `SteamInstallBackend.swift`, `ResumableDepotDownload.swift`, `DownloadEngine.swift`; the job diagnostic log
(`CatalogStore.diagnosticSink`).

- [ ] For each live download run (start to finish, pause, cancel or failure), write one summary event to the job's diagnostic log:
  wall time, compressed and assembled bytes **excluding resumed bytes**, fetch / decrypt-decompress / write / checkpoint / backoff
  time, chunk retries, corrupt-chunk retries, peak busy and peak waiting chunk slots, and the slot count used.
- [ ] Keep the hot path cheap: counters only, one summary write per run. Do not write per-chunk events.
- [ ] Add `scripts/steam-download-report.sh` (or a Swift CLI) that reads a copied catalog or an exported diagnostic archive and prints
  per-run throughput and stage totals. **Never read the live `catalog.sqlite` in a loop** (see step 0).
- [ ] Never log credentials, depot keys or CDN auth tokens.
- [ ] Test that the summary excludes resumed bytes and that a paused run still writes one summary.

**Acceptance:** after a real install, one command shows its real throughput and where the time went.

### 13. Make chunk slots tunable, then choose the default from live runs

PS5 reads a tuning file (slots clamped to 1–8, default 4). The Mac uses a fixed 8 slots (`ResumableDepotDownload.chunkConcurrency`).
The fixture results also show the HFS+ large-file download got slower (+44.9%, mostly sync time), so the right default may differ
between internal and external drives.

- [ ] Add a development-only override for chunk slots (for example a `defaults` key or environment variable), clamped to 1–16.
  Ordinary users never see it.
- [ ] Keep `httpMaximumConnectionsPerHost` at least the slot count.
- [ ] With step 12 stats, run the same real game at 4, 8 and 12 slots on internal APFS and on the external HFS+ drive. Record the
  results in the results document.
- [ ] Change the default only if the data supports it. Do not add per-drive defaults unless the difference is large and repeatable.

**Acceptance:** the default slot count is backed by live measurements.

### 14. Steadier speed and time-left labels

The Mac estimator (`Installs/TransferRateEstimator.swift`) already averages speed over 8 s and time left over 30 s, and updates time
left at most every 5 s. It divides by the real elapsed time, so it does not have the PS5 bug fixed in `8affe33`. Remaining
differences from PS5 `a8cde7b`:

- [ ] Change the speed label at most every 2 s. The queue publishes every second, so today it can change every second.
- [ ] A new or resumed download shows "Measuring…" for its first 3 s (today: 1 s for speed).
- [ ] With no new bytes for 5 s, show 0 speed at once and hide time left. Today the speed decays slowly over the 8 s window.
- [ ] Leaving a stall updates both labels at once; it does not wait for the throttle.
- [ ] Extend `TransferRateEstimatorTests` with an injected clock: warm-up, throttle, stall, recovery after a stall, resume and the
  switch between verification and download.

**Acceptance:** during a steady download the labels do not jump, and a stall shows within 5 s.

### 15. Remove download state for superseded manifests

PS5 resets a journal when its manifest identifiers change (`9c260cd`). On the Mac, a different manifest uses a different
`.gn-download/<depot>/<gid>/` folder, so old partial data cannot be reused by mistake. It can, however, stay on disk.

- [ ] Confirm whether a job can change its pinned manifests (re-resolve, update, repair after a game update). If it can, delete
  `.gn-download/<depot>/<gid>/` folders that are not in the current plan when the download starts, under the destination lease.
- [ ] Test that the current manifest's partials are kept and that a superseded gid's folder is removed.
- [ ] If no job can change its manifests, record that here and close this step.

**Acceptance:** no partial downloads for superseded manifests stay on disk.

## Commit style

- Subject under 60 characters; body wrapped at 140 characters.
- `-` bullets that describe visible behavior, with code names in backticks.
- End with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
