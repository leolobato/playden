# Download speed and ETA — 8 September 2026

Connected PRD 05 FR-INST-2's transfer statistics to Downloads, the game-page progress block and the
compact bottom indicator. All three use the same active queue snapshot and presentation formatter.
They show stage, percent, assembled bytes, network rate and estimated time remaining when measurable.
The compact indicator uses an opaque panel so cover artwork cannot reduce text contrast.

## Counters and lifetime

The active sibling GameNative-macos checkout now includes `6b55eeb` on `investigation/ios-runtime`.
It adds received CDN chunk response-body byte callbacks before decrypt/decompress, plus a separate
fresh validated/committed byte counter in resumable depot progress. Retained chunks and complete
files increase completed bytes but never the fresh counter. Existing user documentation/iOS changes
were preserved. The earlier SteamCore interface fix remains on main and the active branch.

Big Screen aggregates concurrent network callbacks and fresh counters across depots under a lock.
The install queue uses monotonic, invocation-local samples over an eight-second window: compressed
response-body rate for speed, freshly assembled data rate for remaining assembled work. Counters
are not restored from durable progress, and old/out-of-order samples cannot subtract work. Rate
and ETA clear on pause, stage changes, completion and a new invocation. A one-second queue heartbeat
ages stale samples even when no progress callbacks arrive, without writing heartbeat events to disk.

The first second displays Measuring speed. A stalled window shows zero speed and no ETA. Transfer
speed counts completed chunk HTTP response bodies (including a retried body's received bytes),
not headers, TLS overhead or bytes still in an unfinished HTTP response. ETA describes remaining
file transfer/assembly, not later runtime setup. During repair/resume, scanning later cached files
can reduce remaining work and revise the estimate substantially.

## Tests and rendering

- Sibling: 65 tests, 2 existing skips, no failures.
  `/tmp/bigscreen-transfer-steamcore-tests.log`.
- Big Screen package: 184 XCTest tests, 4 existing skips, plus 5 Swift Testing tests passed.
  `/tmp/bigscreen-transfer-all-tests.log`.
- App suite exercised 70 tests; the sole failure was the new test expecting `0 KB/s` when Foundation
  emits `0 bytes/s`. Corrected that test expectation; its targeted rerun passed in
  `/tmp/bigscreen-transfer-ui-retest.log`. The other 69 passed in the full run.
- New tests cover retained chunks and complete files, compressed vs assembled rates, stalls,
  old samples, invocation reset, unsupported counters, concurrent/depot aggregation and hiding
  rates outside the active downloading job.
- Inspected Downloads and game-page captures in `.build/download-transfer-ui/`, the final opaque
  compact indicator in `.build/download-transfer-ui-final/`, and its 4K rendering in
  `.build/download-transfer-ui-4k/`. The final signed build passed and was staged to the live bundle.

## Live repair transfer

With no active session or unfinished job, backed up A Short Hike's
`AShortHike_Data/sharedassets2.assets` (28,665,388 bytes), recorded its SHA-256 and all `.mountain`
save hashes, then removed only that asset to exercise normal Verify files repair. The first run
completed, but its short capture window only observed connection setup. Repeated the controlled
repair with a longer observation window after verifying the first had finished and restored the
asset exactly. Both completed; neither touched saves.

Second job: `BF512743-DCDE-4700-91E7-44CD34C7C27D`. Live accessibility observations captured:

- 642 KB assembled / 616 KB/s before a measurable ETA;
- 242.8 MB assembled / 557 KB/s / 6 min 32 s left;
- 248.1 MB assembled / 911 KB/s / 1 min 5 s left;
- 253.3 MB assembled / 1.2 MB/s / 36 s left;
- 263.7 MB assembled / 1.5 MB/s / 18 s left.

The subsequent verification completed at 331,636,934 total assembled bytes. The repaired asset's
hash equals its backup and all recorded save hashes remain identical. The game remains installed;
no test session or repair job is active. Private evidence: `.build/download-transfer-live/` and
`/tmp/bigscreen-transfer-live-rate.log`. The owned-window capture selected the initial zero-rate
frame; positive rates/ETA are recorded in accessibility observations rather than that screenshot.

Downloads history dismissal and physical drive-disconnection/reconnection acceptance remain open.
