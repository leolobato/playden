# Steam installation measurements after Step 5 — 2026-10-12

Step 5 increases incomplete-file checkpoint cadence to **128 MiB / five seconds**, whichever comes first. Complete files use their final file sync and atomic publication instead of writing a journal about to be deleted. Executable mode precedes the one final sync. Orderly cancellation/pause still checkpoints received work after task-group drainage, even in a cancelled task. Same-directory rename syncs one directory, using device/inode identity of the open descriptors; cross-directory rename retains both syncs. Restore still checks disk bytes against pinned chunks.

## Repeat commands and conditions

```sh
scripts/benchmark-steam-install.sh /private/tmp /tmp/steam-step5-apfs.json 3
scripts/benchmark-steam-install.sh /Volumes/VM /tmp/steam-step5-hfs.json 3
```

Both release runs passed and executed sequentially, APFS then external USB/Journaled HFS+, with no overlapping build or benchmark. Compilation preceded timed phases. The [baseline dataset](2026-10-12-faster-steam-installations-baseline.md), two depots, concurrency eight, 2 ms requested simulated fetch delay, three repetitions and four phases remain unchanged. Host/cache conditions follow prior measurements; caches were not reset. Fixture UUID directories were removed afterward. No live game, catalog or account was accessed.

Raw numeric samples: [APFS JSON](steam-install-baselines/2026-10-12-step-5-apfs.json), [HFS+ JSON](steam-install-baselines/2026-10-12-step-5-hfs.json). All 12 workload repetitions have zero real `networkTransfer` and `sessionCreation` in every phase. The fixture has no HTTP/TLS/decrypt/decompress; simulated fetch latency is not CDN evidence.

## Elapsed phase medians

Comparison uses the last recorded [Step 2 measurements](2026-10-12-faster-steam-installations-step-2.md). It includes Steps 3–5 together: validated incoming chunk handling, native zero-seeded Adler, index-only journals, removal of the final content reread, and this checkpoint/sync change. It does not isolate Step 5 elapsed improvement. Values are Step 2 → Step 5 milliseconds (relative change).

| Volume / fixture | Download | Original verification | Preparation | Final validation |
| --- | --- | --- | --- | --- |
| APFS / large-file | 517.66 → 210.41 (-59.4%) | 49.36 → 50.41 (+2.1%) | 81.85 → 71.00 (-13.3%) | 52.85 → 52.88 (+0.1%) |
| APFS / many-small-files | 2729.97 → 2009.60 (-26.4%) | 66.82 → 52.47 (-21.5%) | 83.18 → 89.67 (+7.8%) | 52.49 → 56.74 (+8.1%) |
| HFS+ / large-file | 3483.64 → 3740.87 (+7.4%) | 51.41 → 52.10 (+1.3%) | 246.63 → 259.88 (+5.4%) | 54.68 → 54.62 (-0.1%) |
| HFS+ / many-small-files | 2631.35 → 2374.90 (-9.7%) | 39.58 → 51.35 (+29.7%) | 253.90 → 263.28 (+3.7%) | 53.48 → 56.63 (+5.9%) |

## Download counter changes

Count/byte fields are identical across corresponding repetitions on both volumes. Values below are Step 2 → Step 5; these compare the combined Steps 3–5 behavior.

| Metric | Large-file count / bytes | Many-small-files count / bytes |
| --- | --- | --- |
| `checkpoint` | 10 / 0 → **0 / 0** | 514 / 0 → **0 / 0** |
| `fileSync` | 23 / 0 → **3 / 0** | 1542 / 0 → **514 / 0** |
| `directorySync` | 26 / 0 → **6 / 0** | 2056 / 0 → **1028 / 0** |
| `directoryWalk` | 63 / 0 → **20 / 0** | 5656 / 0 → **3086 / 0** |
| `fileWrite` | 140 / 134251823 → **130 / 134219776** | 1028 / 8462941 → **514 / 8390656** |
| `contentRead` | 133 / 134219776 → **0 / 0** | 1028 / 8390656 → **0 / 0** |
| `fileValidation` | 6 / 0 → **3 / 0** | 1028 / 0 → **514 / 0** |
| `adler32` | 390 / 402659328 → **130 / 134219776** | 1542 / 25171968 → **514 / 8390656** |
| `sha1` | 136 / 134219776 → **0 / 0** | 1542 / 8390656 → **0 / 0** |
| `sha256` | 136 / 134237204 → **6 / 17428** | 1542 / 8531609 → **1028 / 140953** |
| `progressCallback` | 290 / 0 → **272 / 0** | 6168 / 0 → **3084 / 0** |

Fresh completion performs zero journal checkpoints in every recorded repetition. The large fixture has three file syncs and six directory syncs; the small fixture has 514 file syncs and 1,028 directory syncs. No downloaded content is reread/hashed at final publication. The exact 128 MiB archive finishes at the threshold, so its final chunk uses publication durability rather than a disposable journal. A focused 129 MiB regression separately proves checkpointing at 128 MiB when incomplete. A real-clock test proves no checkpoint at 1.1 seconds, then checkpoint after five seconds while incomplete.

Post-download phase count/byte fields match Step 2 exactly for every metric and repetition. Original verification, preparation and final validation continue their existing full checks until later planned work. Phase tables show field-wise medians as **count / bytes / summed ms**. Metric durations overlap and must not be summed to estimate wall time.

## download

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `adler32` | 130 / 134219776 / 7.058 | 514 / 8390656 / 0.783 | 130 / 134219776 / 7.158 | 514 / 8390656 / 0.989 |
| `directorySync` | 6 / 0 / 0.004 | 1028 / 0 / 1.844 | 6 / 0 / 0.003 | 1028 / 0 / 1.196 |
| `directoryWalk` | 20 / 0 / 0.858 | 3086 / 0 / 203.308 | 20 / 0 / 1.133 | 3086 / 0 / 224.297 |
| `fileSync` | 3 / 0 / 151.832 | 514 / 0 / 79.691 | 3 / 0 / 3536.968 | 514 / 0 / 340.585 |
| `fileValidation` | 3 / 0 / 0.042 | 514 / 0 / 29.124 | 3 / 0 / 0.053 | 514 / 0 / 32.712 |
| `fileWrite` | 130 / 134219776 / 8.876 | 514 / 8390656 / 17.124 | 130 / 134219776 / 33.445 | 514 / 8390656 / 10.462 |
| `progressCallback` | 272 / 0 / 0.079 | 3084 / 0 / 1.685 | 272 / 0 / 0.059 | 3084 / 0 / 2.261 |
| `sha256` | 6 / 17428 / 0.014 | 1028 / 140953 / 2.770 | 6 / 17428 / 0.016 | 1028 / 140953 / 3.611 |

## originalVerification

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `contentRead` | 133 / 134219776 / 7.639 | 1028 / 8390656 / 1.466 | 133 / 134219776 / 8.466 | 1028 / 8390656 / 1.492 |
| `directoryWalk` | 3 / 0 / 0.024 | 514 / 0 / 8.672 | 3 / 0 / 0.033 | 514 / 0 / 8.134 |
| `fileValidation` | 3 / 0 / 49.601 | 514 / 0 / 19.561 | 3 / 0 / 50.764 | 514 / 0 / 19.141 |
| `progressCallback` | 37 / 0 / 0.008 | 5147 / 0 / 0.380 | 37 / 0 / 0.009 | 5147 / 0 / 0.382 |
| `sha1` | 136 / 134219776 / 41.659 | 1542 / 8390656 / 2.805 | 136 / 134219776 / 41.793 | 1542 / 8390656 / 2.821 |

## preparation

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `contentRead` | 153 / 188417344 / 8.634 | 1048 / 62588224 / 2.863 | 153 / 188417344 / 8.910 | 1048 / 62588224 / 3.712 |
| `directoryWalk` | 6 / 0 / 1.019 | 517 / 0 / 25.864 | 6 / 0 / 0.848 | 517 / 0 / 23.425 |
| `emulatorPreparation` | 1 / 0 / 11.585 | 1 / 0 / 32.088 | 1 / 0 / 201.862 | 1 / 0 / 201.501 |
| `fileValidation` | 3 / 0 / 48.379 | 514 / 0 / 19.261 | 3 / 0 / 48.529 | 514 / 0 / 18.272 |
| `preparation` | 1 / 0 / 70.989 | 1 / 0 / 89.664 | 1 / 0 / 259.869 | 1 / 0 / 263.276 |
| `progressCallback` | 58 / 0 / 0.015 | 7212 / 0 / 0.769 | 58 / 0 / 0.015 | 7212 / 0 / 0.790 |
| `sha1` | 136 / 134219776 / 40.929 | 1542 / 8390656 / 2.818 | 136 / 134219776 / 41.114 | 1542 / 8390656 / 2.877 |
| `sha256` | 13 / 33694280 / 11.745 | 13 / 33694280 / 11.177 | 13 / 33694280 / 11.231 | 13 / 33694280 / 11.738 |

## validation

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `contentRead` | 143 / 141526952 / 7.899 | 1038 / 15697832 / 2.246 | 143 / 141526952 / 9.603 | 1038 / 15697832 / 2.684 |
| `directoryWalk` | 4 / 0 / 0.248 | 515 / 0 / 11.043 | 4 / 0 / 0.253 | 515 / 0 / 9.998 |
| `fileValidation` | 3 / 0 / 48.390 | 514 / 0 / 20.346 | 3 / 0 / 49.974 | 514 / 0 / 18.900 |
| `finalValidation` | 1 / 0 / 52.875 | 1 / 0 / 56.730 | 1 / 0 / 54.612 | 1 / 0 / 56.625 |
| `progressCallback` | 58 / 0 / 0.017 | 7212 / 0 / 0.799 | 58 / 0 / 0.018 | 7212 / 0 / 0.746 |
| `sha1` | 136 / 134219776 / 40.840 | 1542 / 8390656 / 2.875 | 136 / 134219776 / 40.911 | 1542 / 8390656 / 2.785 |
| `sha256` | 8 / 7305128 / 2.225 | 8 / 7305128 / 2.228 | 8 / 7305128 / 2.224 | 8 / 7305128 / 2.223 |

## Per-file latency and Step 9 decision

Proceed with Step 9 after the intervening planned work: per-file latency remains material on both volumes. All 514 small-file fetches remain serial across files. The measured simulated sleep/fetch sums are:

| Volume / fixture | Calls / bytes | Simulated fetch samples ms → median | Download median ms |
| --- | ---: | --- | ---: |
| APFS / large-file | 130 / 134219776 | 364.66, 333.99, 365.71 → **364.66** | 210.41 |
| APFS / many-small-files | 514 / 8390656 | 1501.75, 1475.99, 1487.41 → **1487.41** | 2009.60 |
| HFS+ / large-file | 130 / 134219776 | 360.96, 364.35, 370.64 → **364.35** | 3740.87 |
| HFS+ / many-small-files | 514 / 8390656 | 1505.04, 1519.58, 1510.72 → **1510.72** | 2374.90 |

Small-file simulated fetch sums remain about 1.49 s on APFS and 1.51 s on HFS+, about 74% and 64% of their elapsed downloads. Since files are currently processed sequentially, these sums expose per-file latency rather than concurrency overlap. Keep the planned total chunk budget of eight; these results justify investigating file overlap, not increasing network concurrency or claiming real-CDN gains.

HFS+ large-file download is **slower**, 3,740.87 ms versus Step 2's 3,483.64 ms (+7.4%), despite fewer sync calls. Median summed file-sync duration is 3,536.97 ms, compared with 1,984.67 ms before: a single final sync now absorbs delayed writeback that periodic checkpoints previously spread through the transfer. File-write time fell from 1,040.82 to 33.44 ms. This run demonstrates fewer persistence operations, not an external large-file speedup. APFS final-sync timing also varies substantially (large-file elapsed samples 154.65, 397.18, 210.41 ms). Warm caches, external disk writeback and only three samples limit timing attribution. Do not remove the final durability sync to improve benchmark timing.
