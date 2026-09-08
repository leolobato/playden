# Bounded artwork loading — 8 September 2026

The previous cache decoded images and read/wrote artwork files on the main actor, allowed an
unbounded number of outstanding loads, and never evicted disk files. The new `ArtworkLoader`
actor owns file access and eager ImageIO decoding. The UI facade performs memory lookups and wraps
decoded CGImages in NSImages; it keeps the existing 160 MiB memory-cache cost limit, now using
actual decoded byte costs.

- At most four loads run concurrently. Consumers share requests by URL. Cancelling one consumer
  preserves work needed by another; cancelling the last removes queued work or cancels its request.
- The disk cache retains its existing URL hashes and directory, with a 512 MiB least-recently-used
  budget. It indexes/prunes old cache files on first use, touches successful reads, evicts before
  publishing new files, and retains accounting for failed deletions. Unrelated files are untouched.
- Corrupt disk images are fetched again and repaired. Disk write failure still permits display.
  Failed loads have a bounded 30-second cooldown to avoid repeatedly requesting absent art.
- Network downloads use temporary files and bypass URLSession's additional response cache. Only
  HTTP 200 responses up to 16 MiB are decoded/persisted. ImageIO decodes eagerly on the loader actor,
  applies orientation, retains alpha, and limits the longest edge to 4096 pixels.

Validation:
- All 95 app tests passed, including six cache regressions. Tests exercise shared cancellation,
  queued cancellation, disk LRU and offline reopen, startup eviction of legacy files, corruption
  repair, invalid/oversized data, transparent image downsampling and a 600-request stress run.
  The stress run loaded all 600 images with no more than four concurrent loads while retaining
  at most its configured 100-image disk budget. It completed in 0.991 seconds on this run using
  generated images and a controlled transport; this is not a frame-rate measurement.
  `/tmp/bigscreen-artwork-all-app-tests.log`.
- Signed build passed. `/tmp/bigscreen-artwork-build.log`.
- Library/Home/game fixtures rendered at 1080p, with Library/game also rendered at 4K using
  reduced motion. Library covers and the game's hero/transparent logo were visually inspected.
  `.build/artwork-cache-1080/`, `.build/artwork-cache-4k/`. The known offscreen-renderer omission of
  the native game action strip remains; these captures verify artwork rather than live interaction.
- With zero unfinished sessions and zero Cloud claims, the signed app was staged and launched
  from its stable Application Support bundle with normal quit handling. `/tmp/bigscreen-artwork-run.log`.
- Before deployment the real artwork directory contained 647 files totaling 67,171,545 bytes,
  already below the new budget. No game, save or account data was changed by this checkpoint.

FR-LIB-6 remains open until 600+ title cold/warm scrolling is measured in a live window. The desktop
is still locked. Follow-up audit also identified eager Home row construction and repeated library
sorting during focus updates; these need review before claiming the full performance gate.
