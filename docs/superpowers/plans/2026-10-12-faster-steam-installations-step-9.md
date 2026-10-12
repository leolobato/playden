# Steam installation measurements after Step 9 — 2026-10-12

Step 9 admits chunks from an ordered queue across files, with eight total chunk slots and at most eight open file writers. Each file retains its own journal and completes durable publication when its final chunk lands. A bounded Steam progress relay awaits the actual queue actor consumer and drains before stage transitions. The 128 MiB/five-second checkpoint policy and final file/directory syncs remain in place.

## Repeat commands and conditions

```sh
scripts/benchmark-steam-install.sh /private/tmp docs/superpowers/plans/steam-install-baselines/2026-10-12-step-9-apfs.json 3
scripts/benchmark-steam-install.sh /Volumes/VM docs/superpowers/plans/steam-install-baselines/2026-10-12-step-9-hfs.json 3
```

Both unchanged release fixture runs passed, sequentially on internal APFS and then USB Journaled HFS+. Volume types were checked with `diskutil info`. Package suites had finished before the benchmarks; compilation preceded timed phases. Only new UUID fixture directories were created and automatically removed. No live catalog, account, app or game was accessed or stopped.

The [baseline dataset](2026-10-12-faster-steam-installations-baseline.md) remains unchanged: two depots, three repetitions, eight chunk slots, 2 ms requested simulated fetch latency, the same file/chunk counts and bytes, and the same four phases. Raw sample metadata and simulated byte/call counts were checked against step 5. Caches were not reset.

Raw samples: [APFS JSON](steam-install-baselines/2026-10-12-step-9-apfs.json), [HFS+ JSON](steam-install-baselines/2026-10-12-step-9-hfs.json). All twelve fixture repetitions have **zero actual network transfer and session creation counts/bytes/time in every phase**. This plaintext fixture does not exercise HTTP, TLS, decrypt or decompress, and its simulated latency provides no live CDN throughput evidence.

## Elapsed phase medians

Values are [step 5](2026-10-12-faster-steam-installations-step-5.md) → step 9 milliseconds (relative change). The comparison includes steps 6–9 together: receipt retention, receipt-assisted normal verification, scoped preparation and file overlap. It does not isolate the scheduler from those intervening changes.

| Volume / fixture | Download | Original verification | Preparation | Final validation |
| --- | --- | --- | --- | --- |
| APFS / large-file | 210.41 → 137.04 (-34.9%) | 50.41 → 1.20 (-97.6%) | 71.00 → 20.12 (-71.7%) | 52.88 → 5.42 (-89.7%) |
| APFS / many-small-files | 2009.60 → 309.20 (-84.6%) | 52.47 → 41.54 (-20.8%) | 89.67 → 75.73 (-15.5%) | 56.74 → 53.96 (-4.9%) |
| HFS+ / large-file | 3740.87 → 3883.99 (+3.8%) | 52.10 → 1.85 (-96.5%) | 259.88 → 238.11 (-8.4%) | 54.62 → 6.18 (-88.7%) |
| HFS+ / many-small-files | 2374.90 → 539.93 (-77.3%) | 51.35 → 36.05 (-29.8%) | 263.28 → 253.80 (-3.6%) | 56.63 → 50.52 (-10.8%) |

## Download samples and simulated fetch sums

Fetch durations below sum concurrent tasks, so they can exceed elapsed time. Equal requested latency does not imply equal observed sleep duration.

| Volume / fixture | Download samples ms → median | Simulated calls / bytes | Simulated fetch samples ms → median |
| --- | --- | --- | --- |
| APFS / large-file | 137.04, 269.11, 80.35 → **137.04** | 130 / 134219776 | 369.95, 361.71, 368.90 → **368.90** |
| APFS / many-small-files | 262.91, 309.20, 361.82 → **309.20** | 514 / 8390656 | 1153.32, 1172.64, 1207.18 → **1172.64** |
| HFS+ / large-file | 3883.99, 3809.40, 4160.28 → **3883.99** | 130 / 134219776 | 357.57, 348.94, 372.02 → **357.57** |
| HFS+ / many-small-files | 545.95, 513.50, 539.93 → **539.93** | 514 / 8390656 | 1231.40, 1250.51, 1277.65 → **1250.51** |

Both small-file medians improve: APFS **2,009.60 → 309.20 ms (-84.6%)**, HFS+ **2,374.90 → 539.93 ms (-77.3%)**. Focused scheduler tests demonstrate eight overlapping small-file fetches, an eight-worker cap even when configured larger, bounded active writers, drained cancellation/failure, and accurate resumed/fresh progress. Keep the default eight; these measurements do not justify increasing network concurrency.

HFS+ large-file download is **slower: 3,740.87 → 3,883.99 ms (+3.8%)**. Its step-9 samples range from 3,809.40 to 4,160.28 ms; final sync/writeback dominates. The final durability sync remains mandatory. APFS large-file samples also vary substantially. Three warm-cache samples and external-drive writeback limit timing attribution; no default was tuned separately for either drive.

The download now has two receipt checkpoints and two extra file syncs (one per depot) from step 6. `fileWrite` includes those receipt JSON bytes; their metadata sizes can vary by volume/run. Simulated payload bytes remain exactly unchanged. HFS+ large-file median summed file-sync time is 3,826.01 ms, explaining most of its 3,883.99 ms elapsed download.

## Phase counters

Each cell shows median **count / bytes / milliseconds** as **step 5 → step 9**. These are medians of each field, not necessarily a single run. Raw JSON retains all values. Metrics that are zero for every comparison are omitted; actual network/session metrics are zero as stated above.

### download

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `adler32` | 130 / 134219776 / 7.058 → 130 / 134219776 / 7.099 | 514 / 8390656 / 0.783 → 514 / 8390656 / 0.412 | 130 / 134219776 / 7.158 → 130 / 134219776 / 8.913 | 514 / 8390656 / 0.989 → 514 / 8390656 / 0.442 |
| `checkpoint` | 0 / 0 / 0.000 → 2 / 0 / 0.534 | 0 / 0 / 0.000 → 2 / 0 / 2.143 | 0 / 0 / 0.000 → 2 / 0 / 1.030 | 0 / 0 / 0.000 → 2 / 0 / 6.342 |
| `directorySync` | 6 / 0 / 0.004 → 12 / 0 / 0.007 | 1028 / 0 / 1.844 → 1034 / 0 / 1.086 | 6 / 0 / 0.003 → 12 / 0 / 0.006 | 1028 / 0 / 1.196 → 1034 / 0 / 0.502 |
| `directoryWalk` | 20 / 0 / 0.858 → 35 / 0 / 1.116 | 3086 / 0 / 203.308 → 3612 / 0 / 106.811 | 20 / 0 / 1.133 → 35 / 0 / 1.161 | 3086 / 0 / 224.297 → 3612 / 0 / 96.065 |
| `fileSync` | 3 / 0 / 151.832 → 5 / 0 / 79.245 | 514 / 0 / 79.691 → 516 / 0 / 74.288 | 3 / 0 / 3536.968 → 5 / 0 / 3826.014 | 514 / 0 / 340.585 → 516 / 0 / 322.341 |
| `fileValidation` | 3 / 0 / 0.042 → 3 / 0 / 0.031 | 514 / 0 / 29.124 → 514 / 0 / 12.180 | 3 / 0 / 0.053 → 3 / 0 / 0.034 | 514 / 0 / 32.712 → 514 / 0 / 11.110 |
| `fileWrite` | 130 / 134219776 / 8.876 → 132 / 134220890 / 8.997 | 514 / 8390656 / 17.124 → 516 / 8570521 / 66.150 | 130 / 134219776 / 33.445 → 132 / 134220809 / 25.193 | 514 / 8390656 / 10.462 → 516 / 8556643 / 6.543 |
| `progressCallback` | 272 / 0 / 0.079 → 266 / 0 / 0.044 | 3084 / 0 / 1.685 → 2056 / 0 / 0.269 | 272 / 0 / 0.059 → 266 / 0 / 0.069 | 3084 / 0 / 2.261 → 2056 / 0 / 0.262 |
| `sha256` | 6 / 17428 / 0.014 → 9 / 34813 / 0.028 | 1028 / 140953 / 2.770 → 1542 / 270021 / 1.191 | 6 / 17428 / 0.016 → 9 / 34813 / 0.030 | 1028 / 140953 / 3.611 → 1542 / 270021 / 1.177 |

### originalVerification

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `contentRead` | 133 / 134219776 / 7.639 → 0 / 0 / 0.000 | 1028 / 8390656 / 1.466 → 0 / 0 / 0.000 | 133 / 134219776 / 8.466 → 0 / 0 / 0.000 | 1028 / 8390656 / 1.492 → 0 / 0 / 0.000 |
| `directoryWalk` | 3 / 0 / 0.024 → 7 / 0 / 0.099 | 514 / 0 / 8.672 → 518 / 0 / 9.671 | 3 / 0 / 0.033 → 7 / 0 / 0.103 | 514 / 0 / 8.134 → 518 / 0 / 8.184 |
| `fileValidation` | 3 / 0 / 49.601 → 0 / 0 / 0.000 | 514 / 0 / 19.561 → 0 / 0 / 0.000 | 3 / 0 / 50.764 → 0 / 0 / 0.000 | 514 / 0 / 19.141 → 0 / 0 / 0.000 |
| `progressCallback` | 37 / 0 / 0.008 → 19 / 0 / 0.002 | 5147 / 0 / 0.380 → 2063 / 0 / 0.120 | 37 / 0 / 0.009 → 19 / 0 / 0.002 | 5147 / 0 / 0.382 → 2063 / 0 / 0.118 |
| `sha1` | 136 / 134219776 / 41.659 → 0 / 0 / 0.000 | 1542 / 8390656 / 2.805 → 0 / 0 / 0.000 | 136 / 134219776 / 41.793 → 0 / 0 / 0.000 | 1542 / 8390656 / 2.821 → 0 / 0 / 0.000 |
| `sha256` | 0 / 0 / 0.000 → 3 / 17385 / 0.009 | 0 / 0 / 0.000 → 514 / 129068 / 0.319 | 0 / 0 / 0.000 → 3 / 17385 / 0.010 | 0 / 0 / 0.000 → 514 / 129068 / 0.304 |

### preparation

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `contentRead` | 153 / 188417344 / 8.634 → 20 / 54197568 / 1.473 | 1048 / 62588224 / 2.863 → 20 / 54197568 / 1.368 | 153 / 188417344 / 8.910 → 20 / 54197568 / 2.360 | 1048 / 62588224 / 3.712 → 20 / 54197568 / 1.239 |
| `directoryWalk` | 6 / 0 / 1.019 → 7 / 0 / 0.084 | 517 / 0 / 25.864 → 518 / 0 / 12.436 | 6 / 0 / 0.848 → 7 / 0 / 0.080 | 517 / 0 / 23.425 → 518 / 0 / 8.091 |
| `emulatorPreparation` | 1 / 0 / 11.585 → 1 / 0 / 9.466 | 1 / 0 / 32.088 → 1 / 0 / 10.659 | 1 / 0 / 201.862 → 1 / 0 / 215.734 | 1 / 0 / 201.501 → 1 / 0 / 199.734 |
| `fileValidation` | 3 / 0 / 48.379 → 0 / 0 / 0.000 | 514 / 0 / 19.261 → 0 / 0 / 0.000 | 3 / 0 / 48.529 → 0 / 0 / 0.000 | 514 / 0 / 18.272 → 0 / 0 / 0.000 |
| `preparation` | 1 / 0 / 70.989 → 1 / 0 / 20.116 | 1 / 0 / 89.664 → 1 / 0 / 75.728 | 1 / 0 / 259.869 → 1 / 0 / 238.107 | 1 / 0 / 263.276 → 1 / 0 / 253.790 |
| `progressCallback` | 58 / 0 / 0.015 → 34 / 0 / 0.005 | 7212 / 0 / 0.769 → 3100 / 0 / 0.338 | 58 / 0 / 0.015 → 34 / 0 / 0.004 | 7212 / 0 / 0.790 → 3100 / 0 / 0.280 |
| `sha1` | 136 / 134219776 / 40.929 → 0 / 0 / 0.000 | 1542 / 8390656 / 2.818 → 0 / 0 / 0.000 | 136 / 134219776 / 41.114 → 0 / 0 / 0.000 | 1542 / 8390656 / 2.877 → 0 / 0 / 0.000 |
| `sha256` | 13 / 33694280 / 11.745 → 16 / 33711665 / 11.834 | 13 / 33694280 / 11.177 → 527 / 33823348 / 11.796 | 13 / 33694280 / 11.231 → 16 / 33711665 / 23.943 | 13 / 33694280 / 11.738 → 527 / 33823348 / 11.311 |

### validation

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `checkpoint` | 0 / 0 / 0.000 → 1 / 0 / 0.304 | 0 / 0 / 0.000 → 1 / 0 / 0.322 | 0 / 0 / 0.000 → 1 / 0 / 0.477 | 0 / 0 / 0.000 → 1 / 0 / 0.476 |
| `contentRead` | 143 / 141526952 / 7.899 → 12 / 7308200 / 0.805 | 1038 / 15697832 / 2.246 → 12 / 7308200 / 0.613 | 143 / 141526952 / 9.603 → 12 / 7308200 / 1.156 | 1038 / 15697832 / 2.684 → 12 / 7308200 / 1.024 |
| `directorySync` | 0 / 0 / 0.000 → 1 / 0 / 0.001 | 0 / 0 / 0.000 → 1 / 0 / 0.001 | 0 / 0 / 0.000 → 1 / 0 / 0.000 | 0 / 0 / 0.000 → 1 / 0 / 0.000 |
| `directoryWalk` | 4 / 0 / 0.248 → 12 / 0 / 0.203 | 515 / 0 / 11.043 → 523 / 0 / 9.621 | 4 / 0 / 0.253 → 12 / 0 / 0.213 | 515 / 0 / 9.998 → 523 / 0 / 8.021 |
| `fileSync` | 0 / 0 / 0.000 → 1 / 0 / 0.023 | 0 / 0 / 0.000 → 1 / 0 / 0.025 | 0 / 0 / 0.000 → 1 / 0 / 0.238 | 0 / 0 / 0.000 → 1 / 0 / 0.254 |
| `fileValidation` | 3 / 0 / 48.390 → 1 / 0 / 0.176 | 514 / 0 / 20.346 → 1 / 0 / 0.233 | 3 / 0 / 49.974 → 1 / 0 / 0.620 | 514 / 0 / 18.900 → 1 / 0 / 0.394 |
| `fileWrite` | 0 / 0 / 0.000 → 1 / 379 / 0.021 | 0 / 0 / 0.000 → 1 / 379 / 0.031 | 0 / 0 / 0.000 → 1 / 352 / 0.009 | 0 / 0 / 0.000 → 1 / 352 / 0.008 |
| `finalValidation` | 1 / 0 / 52.875 → 1 / 0 / 5.406 | 1 / 0 / 56.730 → 1 / 0 / 53.948 | 1 / 0 / 54.612 → 1 / 0 / 6.172 | 1 / 0 / 56.625 → 1 / 0 / 50.517 |
| `progressCallback` | 58 / 0 / 0.017 → 42 / 0 / 0.007 | 7212 / 0 / 0.799 → 3108 / 0 / 0.300 | 58 / 0 / 0.018 → 42 / 0 / 0.008 | 7212 / 0 / 0.746 → 3108 / 0 / 0.281 |
| `sha1` | 136 / 134219776 / 40.840 → 3 / 1024 / 0.003 | 1542 / 8390656 / 2.875 → 3 / 1024 / 0.004 | 136 / 134219776 / 40.911 → 3 / 1024 / 0.004 | 1542 / 8390656 / 2.785 → 3 / 1024 / 0.003 |
| `sha256` | 8 / 7305128 / 2.225 → 10 / 7322270 / 2.222 | 8 / 7305128 / 2.228 → 521 / 7433953 / 2.543 | 8 / 7305128 / 2.224 → 10 / 7322270 / 2.242 | 8 / 7305128 / 2.223 → 521 / 7433953 / 2.598 |
