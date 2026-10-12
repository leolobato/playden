# Final Steam installation results

Final validation of the faster Steam installation plan on 2026-10-12. Steam Windows and native Mac use validated chunk writes, receipt-assisted ordinary checks, strict full repair and original-backup hashes, bounded file concurrency, and allocation-based reservations. Other stores retain their existing paths; the catalog contention fix applies to all stores.

## Measurement conditions

The original [baseline](2026-10-12-faster-steam-installations-baseline.md) and every intermediate raw JSON remain unchanged. Final release fixtures ran sequentially on internal APFS (`/private/tmp`) and external USB Journaled HFS+ (`/Volumes/VM`), three fresh UUID directories per workload per drive, automatically removed by the fixture. No concurrent benchmark/build workload ran during timed samples. Caches were not reset. Three warm samples cannot characterize cold caches, large real games, or drive writeback distributions.

```sh
scripts/benchmark-steam-install.sh /private/tmp docs/superpowers/plans/steam-install-baselines/2026-10-12-final-apfs.json 3
scripts/benchmark-steam-install.sh /Volumes/VM docs/superpowers/plans/steam-install-baselines/2026-10-12-final-hfs.json 3
```

The fixed fixtures preserve two depots, eight chunk slots, requested 2 ms fetch latency, and the baseline content: 134,219,776 bytes / 3 files / 130 chunks for large-file; 8,390,656 bytes / 514 files / 514 chunks for many-small-files. Timing excludes construction and builds. The plaintext in-memory fetch validates chunks but performs no HTTP/TLS/decrypt/decompression: **all actual network and session counters are zero**. Simulated fetch is recorded separately. These results make no live CDN throughput claim. No live account, catalog, game installation, or app was used.

Raw results: [APFS](steam-install-baselines/2026-10-12-final-apfs.json), [HFS+](steam-install-baselines/2026-10-12-final-hfs.json). Each comparison below is ORIGINAL baseline → final; intermediate results are not substituted for the baseline.

## Phase elapsed medians

Milliseconds; relative change in parentheses. Total is the median of each repetition’s four-phase sum.

| Volume / workload | Download | Original verification | Preparation | Validation | Total |
| --- | --- | --- | --- | --- | --- |
| APFS / large-file | 610.99 → 266.81 (-56.3%) | 49.91 → 1.38 (-97.2%) | 79.29 → 40.07 (-49.5%) | 57.72 → 6.73 (-88.3%) | 791.27 → 348.24 (-56.0%) |
| APFS / many-small-files | 2567.25 → 254.94 (-90.1%) | 52.16 → 41.03 (-21.3%) | 83.74 → 77.39 (-7.6%) | 53.88 → 57.60 (+6.9%) | 2755.31 → 432.11 (-84.3%) |
| HFS+ / large-file | 3484.86 → 5049.63 (+44.9%) | 50.42 → 1.76 (-96.5%) | 254.74 → 234.43 (-8.0%) | 53.14 → 5.97 (-88.8%) | 3839.38 → 5354.84 (+39.5%) |
| HFS+ / many-small-files | 2934.05 → 514.70 (-82.5%) | 50.71 → 38.53 (-24.0%) | 285.91 → 260.19 (-9.0%) | 58.58 → 66.82 (+14.1%) | 3330.99 → 890.08 (-73.3%) |

Slower observed cases: APFS many-small-files validation: 53.88 → 57.60 ms (+6.9%). HFS+ large-file download: 3484.86 → 5049.63 ms (+44.9%). HFS+ large-file total: 3839.38 → 5354.84 ms (+39.5%). HFS+ many-small-files validation: 58.58 → 66.82 ms (+14.1%).

Compared with step 9, final large-file download operation counts remain identical: 5 file syncs, 12 directory syncs, 132 writes, 2 receipt checkpoints and zero content rereads. Median summed file-sync time increased from 79.25 to 198.27 ms on APFS and 3,826.01 to 4,931.68 ms on HFS+. This locates measured extra time in sync work; it does not establish why the host/drive took longer. No rerun was used to replace slower samples.

These are combined branch effects, not isolated attribution to one optimization. Mandatory publication fsync remains in place; external-drive final writeback and cache state can dominate large-file timing.

## All phase counters

Every metric is included, including zero values. Each cell is median **count / bytes / summed milliseconds**, baseline → final. Count, byte and duration medians are independent and need not describe one repetition. Concurrent and nested operation durations overlap; do not add them to infer wall time. Receipt JSON metadata sizes can vary between runs and volumes. Directory-walk instrumentation includes bounded path/parent checks as well as any discovery walks. Aggregate callback counts cover instrumented layers; the queue relay separately bounds delivery.

### download

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `adler32` | 390 / 402659328 / 1017.785 → 130 / 134219776 / 8.058 | 1542 / 25171968 / 112.724 → 514 / 8390656 / 0.436 | 390 / 402659328 / 987.584 → 130 / 134219776 / 7.663 | 1542 / 25171968 / 112.784 → 514 / 8390656 / 0.430 |
| `checkpoint` | 10 / 0 / 67.361 → 2 / 0 / 0.580 | 514 / 0 / 408.160 → 2 / 0 / 2.002 | 10 / 0 / 1995.845 → 2 / 0 / 1.020 | 514 / 0 / 852.469 → 2 / 0 / 6.923 |
| `contentRead` | 133 / 134219776 / 7.469 → 0 / 0 / 0.000 | 1028 / 8390656 / 6.916 → 0 / 0 / 0.000 | 133 / 134219776 / 7.597 → 0 / 0 / 0.000 | 1028 / 8390656 / 6.434 → 0 / 0 / 0.000 |
| `directorySync` | 26 / 0 / 0.017 → 12 / 0 / 0.008 | 2056 / 0 / 2.936 → 1034 / 0 / 0.979 | 26 / 0 / 0.010 → 12 / 0 / 0.006 | 2056 / 0 / 1.541 → 1034 / 0 / 0.442 |
| `directoryWalk` | 63 / 0 / 3.482 → 35 / 0 / 1.205 | 5656 / 0 / 396.273 → 3612 / 0 / 110.006 | 63 / 0 / 3.269 → 35 / 0 / 20.301 | 5656 / 0 / 416.023 → 3612 / 0 / 101.025 |
| `emulatorPreparation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `fileSync` | 23 / 0 / 59.820 → 5 / 0 / 198.267 | 1542 / 0 / 69.499 → 516 / 0 / 28.140 | 23 / 0 / 1988.403 → 5 / 0 / 4931.683 | 1542 / 0 / 504.618 → 516 / 0 / 319.455 |
| `fileValidation` | 6 / 0 / 50.834 → 3 / 0 / 0.034 | 1028 / 0 / 98.208 → 514 / 0 / 12.599 | 6 / 0 / 50.194 → 3 / 0 / 0.034 | 1028 / 0 / 96.613 → 514 / 0 / 10.302 |
| `fileWrite` | 140 / 134251823 / 63.619 → 132 / 134220890 / 8.863 | 1028 / 8462941 / 41.638 → 516 / 8570521 / 16.185 | 140 / 134251823 / 1064.163 → 132 / 134220809 / 23.928 | 1028 / 8462941 / 16.556 → 516 / 8556643 / 3.172 |
| `finalValidation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `keyPreparation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `networkTransfer` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `preparation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `progressCallback` | 290 / 0 / 0.224 → 266 / 0 / 0.049 | 6168 / 0 / 4.132 → 2056 / 0 / 0.295 | 290 / 0 / 0.410 → 266 / 0 / 0.047 | 6168 / 0 / 3.810 → 2056 / 0 / 0.237 |
| `sessionCreation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `sha1` | 136 / 134219776 / 43.110 → 0 / 0 / 0.000 | 1542 / 8390656 / 6.281 → 0 / 0 / 0.000 | 136 / 134219776 / 42.195 → 0 / 0 / 0.000 | 1542 / 8390656 / 6.279 → 0 / 0 / 0.000 |
| `sha256` | 136 / 134237204 / 45.200 → 9 / 34813 / 0.029 | 1542 / 8531609 / 10.002 → 1542 / 270021 / 1.159 | 136 / 134237204 / 43.922 → 9 / 34813 / 0.030 | 1542 / 8531609 / 9.963 → 1542 / 270021 / 1.109 |

### originalVerification

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `adler32` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `checkpoint` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `contentRead` | 133 / 134219776 / 7.285 → 0 / 0 / 0.000 | 1028 / 8390656 / 1.381 → 0 / 0 / 0.000 | 133 / 134219776 / 7.488 → 0 / 0 / 0.000 | 1028 / 8390656 / 1.864 → 0 / 0 / 0.000 |
| `directorySync` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `directoryWalk` | 3 / 0 / 0.025 → 7 / 0 / 0.102 | 514 / 0 / 8.214 → 518 / 0 / 9.202 | 3 / 0 / 0.026 → 7 / 0 / 0.098 | 514 / 0 / 9.557 → 518 / 0 / 8.160 |
| `emulatorPreparation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `fileSync` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `fileValidation` | 3 / 0 / 49.096 → 0 / 0 / 0.000 | 514 / 0 / 18.628 → 0 / 0 / 0.000 | 3 / 0 / 49.532 → 0 / 0 / 0.000 | 514 / 0 / 21.245 → 0 / 0 / 0.000 |
| `fileWrite` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `finalValidation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `keyPreparation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `networkTransfer` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `preparation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `progressCallback` | 37 / 0 / 0.008 → 19 / 0 / 0.002 | 5147 / 0 / 0.459 → 2063 / 0 / 0.130 | 37 / 0 / 0.008 → 19 / 0 / 0.002 | 5147 / 0 / 0.458 → 2063 / 0 / 0.116 |
| `sessionCreation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `sha1` | 136 / 134219776 / 41.634 → 0 / 0 / 0.000 | 1542 / 8390656 / 2.800 → 0 / 0 / 0.000 | 136 / 134219776 / 41.457 → 0 / 0 / 0.000 | 1542 / 8390656 / 2.970 → 0 / 0 / 0.000 |
| `sha256` | 0 / 0 / 0.000 → 3 / 17385 / 0.009 | 0 / 0 / 0.000 → 514 / 129068 / 0.290 | 0 / 0 / 0.000 → 3 / 17385 / 0.009 | 0 / 0 / 0.000 → 514 / 129068 / 0.292 |

### preparation

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `adler32` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `checkpoint` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `contentRead` | 153 / 188417344 / 10.056 → 20 / 54197568 / 1.697 | 1048 / 62588224 / 2.828 → 20 / 54197568 / 1.430 | 153 / 188417344 / 8.997 → 20 / 54197568 / 1.838 | 1048 / 62588224 / 12.071 → 20 / 54197568 / 1.860 |
| `directorySync` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `directoryWalk` | 6 / 0 / 1.145 → 7 / 0 / 0.077 | 517 / 0 / 24.194 → 518 / 0 / 9.507 | 6 / 0 / 0.910 → 7 / 0 / 0.077 | 517 / 0 / 27.188 → 518 / 0 / 7.956 |
| `emulatorPreparation` | 1 / 0 / 18.092 → 1 / 0 / 28.385 | 1 / 0 / 25.866 → 1 / 0 / 9.243 | 1 / 0 / 194.473 → 1 / 0 / 207.164 | 1 / 0 / 216.313 → 1 / 0 / 195.025 |
| `fileSync` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `fileValidation` | 3 / 0 / 50.865 → 0 / 0 / 0.000 | 514 / 0 / 18.138 → 0 / 0 / 0.000 | 3 / 0 / 48.951 → 0 / 0 / 0.000 | 514 / 0 / 24.728 → 0 / 0 / 0.000 |
| `fileWrite` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `finalValidation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `keyPreparation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `networkTransfer` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `preparation` | 1 / 0 / 79.283 → 1 / 0 / 40.061 | 1 / 0 / 83.733 → 1 / 0 / 77.383 | 1 / 0 / 254.729 → 1 / 0 / 234.246 | 1 / 0 / 285.900 → 1 / 0 / 260.179 |
| `progressCallback` | 58 / 0 / 0.016 → 34 / 0 / 0.005 | 7212 / 0 / 0.926 → 3100 / 0 / 0.364 | 58 / 0 / 0.014 → 34 / 0 / 0.005 | 7212 / 0 / 0.945 → 3100 / 0 / 0.280 |
| `sessionCreation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `sha1` | 136 / 134219776 / 42.571 → 0 / 0 / 0.000 | 1542 / 8390656 / 2.823 → 0 / 0 / 0.000 | 136 / 134219776 / 41.470 → 0 / 0 / 0.000 | 1542 / 8390656 / 3.041 → 0 / 0 / 0.000 |
| `sha256` | 13 / 33694280 / 13.312 → 16 / 33711665 / 11.583 | 13 / 33694280 / 11.181 → 527 / 33823348 / 11.598 | 13 / 33694280 / 11.181 → 16 / 33711665 / 24.185 | 13 / 33694280 / 11.449 → 527 / 33823348 / 11.608 |

### validation

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `adler32` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `checkpoint` | 0 / 0 / 0.000 → 1 / 0 / 0.625 | 0 / 0 / 0.000 → 1 / 0 / 0.331 | 0 / 0 / 0.000 → 1 / 0 / 0.507 | 0 / 0 / 0.000 → 1 / 0 / 0.553 |
| `contentRead` | 143 / 141526952 / 9.142 → 12 / 7308200 / 1.401 | 1038 / 15697832 / 2.249 → 12 / 7308200 / 0.596 | 143 / 141526952 / 8.013 → 12 / 7308200 / 0.963 | 1038 / 15697832 / 2.838 → 12 / 7308200 / 1.227 |
| `directorySync` | 0 / 0 / 0.000 → 1 / 0 / 0.003 | 0 / 0 / 0.000 → 1 / 0 / 0.001 | 0 / 0 / 0.000 → 1 / 0 / 0.000 | 0 / 0 / 0.000 → 1 / 0 / 0.000 |
| `directoryWalk` | 4 / 0 / 0.273 → 12 / 0 / 0.355 | 515 / 0 / 10.255 → 523 / 0 / 9.395 | 4 / 0 / 0.276 → 12 / 0 / 0.210 | 515 / 0 / 10.565 → 523 / 0 / 9.685 |
| `emulatorPreparation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `fileSync` | 0 / 0 / 0.000 → 1 / 0 / 0.075 | 0 / 0 / 0.000 → 1 / 0 / 0.025 | 0 / 0 / 0.000 → 1 / 0 / 0.260 | 0 / 0 / 0.000 → 1 / 0 / 0.270 |
| `fileValidation` | 3 / 0 / 51.959 → 1 / 0 / 0.341 | 514 / 0 / 18.809 → 1 / 0 / 0.195 | 3 / 0 / 48.612 → 1 / 0 / 0.392 | 514 / 0 / 21.953 → 1 / 0 / 0.742 |
| `fileWrite` | 0 / 0 / 0.000 → 1 / 379 / 0.046 | 0 / 0 / 0.000 → 1 / 379 / 0.024 | 0 / 0 / 0.000 → 1 / 352 / 0.007 | 0 / 0 / 0.000 → 1 / 352 / 0.009 |
| `finalValidation` | 1 / 0 / 57.715 → 1 / 0 / 6.724 | 1 / 0 / 53.869 → 1 / 0 / 57.591 | 1 / 0 / 53.139 → 1 / 0 / 5.965 | 1 / 0 / 58.569 → 1 / 0 / 66.807 |
| `keyPreparation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `networkTransfer` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `preparation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `progressCallback` | 58 / 0 / 0.017 → 42 / 0 / 0.009 | 7212 / 0 / 0.773 → 3108 / 0 / 0.290 | 58 / 0 / 0.016 → 42 / 0 / 0.008 | 7212 / 0 / 0.753 → 3108 / 0 / 0.368 |
| `sessionCreation` | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 | 0 / 0 / 0.000 → 0 / 0 / 0.000 |
| `sha1` | 136 / 134219776 / 42.885 → 3 / 1024 / 0.004 | 1542 / 8390656 / 2.858 → 3 / 1024 / 0.004 | 136 / 134219776 / 40.910 → 3 / 1024 / 0.004 | 1542 / 8390656 / 2.837 → 3 / 1024 / 0.004 |
| `sha256` | 8 / 7305128 / 2.245 → 10 / 7322270 / 2.548 | 8 / 7305128 / 2.223 → 521 / 7433953 / 2.506 | 8 / 7305128 / 2.234 → 10 / 7322270 / 2.292 | 8 / 7305128 / 2.270 → 521 / 7433953 / 2.724 |

## Individual samples and simulated fetch

| Volume / workload | Final download samples ms | Baseline → final simulated fetch count / bytes / summed ms |
| --- | --- | --- |
| APFS / large-file | 266.81, 297.61, 103.49 | 130 / 134219776 / 375.391 → 130 / 134219776 / 380.905 |
| APFS / many-small-files | 250.93, 259.10, 254.94 | 514 / 8390656 / 1482.889 → 514 / 8390656 / 1147.944 |
| HFS+ / large-file | 5049.63, 5173.33, 5007.04 | 130 / 134219776 / 375.911 → 130 / 134219776 / 380.293 |
| HFS+ / many-small-files | 531.11, 501.57, 514.70 | 514 / 8390656 / 1492.811 → 514 / 8390656 / 1286.474 |

## Connection reuse

```sh
PLAYDEN_STEAM_CDN_BENCHMARK_OUTPUT="$PWD/docs/superpowers/plans/steam-install-baselines/2026-10-12-final-http.json" swift test -c release --package-path Packages/SteamKit --filter CDNTransportBenchmarkTests.testHTTPConnectionReuseIfRequested
```

The independent real loopback HTTP benchmark exercises 64 requests, alternating per-request/shared transport for three repetitions. [Original step-2 raw data](steam-install-baselines/2026-10-12-step-2-http.json) and [final raw data](steam-install-baselines/2026-10-12-final-http.json) preserve the evidence: all shared repetitions use one URLSession, with final TCP counts **1, 1, 2**; per-request mode uses 64 sessions and 64 connections each; both receive 448 body bytes. The optional final benchmark exited **1** because its exact-one-TCP assertion failed in shared repetition 3. Its raw data is preserved, not replaced by a rerun. Prior step-2 shared TCP counts were all 1. Final median elapsed time was 26.58 ms per-request and 11.20 ms shared. This still demonstrates session reuse and substantial connection reuse, but does not support a guarantee of one TCP connection per session. Source inspection found a lazy single URLSession with a permitted connection pool; the extra connection’s precise cause was not established. The controller approved a narrow test correction: shared mode now asserts accepted connections are fewer than requests, while retaining exact one-session/64-request/448-byte assertions. `KeepAliveHTTPFixture` counts every accepted socket under lock, independently of requests; it can count a connection that carries no request. It sends keep-alive replies and loops over requests. No production transport change was made. One [separate recheck dataset](steam-install-baselines/2026-10-12-final-http-recheck.json) passed (exit 0), with shared TCP counts **3, 2, 1**, one session in each sample, and per-request counts still 64. Recheck median elapsed times were 28.80 ms per-request and 14.09 ms shared. This test correction checks the planned connection-pool reuse contract and leaves the original failed assertion/data visible. This is HTTP transport evidence, not TLS/CDN measurement. `CDNTransportTests` additionally cover cancellation isolation, timeouts, no cookies/cache, retry/failover and corrupt responses before writer commit.

## Requirement evidence map

Source filenames resolve under `Packages/SteamKit/Sources/SteamCore`, `Packages/PlaydenKit/Sources/Sources`, `Installs`, `Domain`, `Runner` or `Catalog`; tests are in the corresponding package test target. These are current-source/test pointers, with fresh full-suite execution recorded below. Original historical line numbers in the requirements are retained as plan context, not current line references.

### Step 0

`CatalogStore.swift` retains delete journaling/full durability and a five-second busy timeout. `CatalogStoreTests.testWriteWaitsForExternalReadTransaction` proves contention waits. `InstallQueueTests.testDownloadProgressSaveFailureIsAdvisoryAndRetries` and `testDownloadVerificationProgressSaveFailureIsAdvisoryAndRetries` prove memory survives a rejected save and a subsequent update persists; the latter now observes verification while the rejection trigger is still installed. Stage/commit/uninstall/terminal error/pause/cancel tests prove real checkpoints halt the queue. No WAL migration was made. The controller’s original `feat/gtav` inspection found no existing fix to reuse. Live stuck-job recovery was conditional and inapplicable because no running Playden installation was available; no relaunch or polling was performed.

### Step 1

Source: `SteamPerformanceDiagnostics.swift; DownloadEngine.swift; SteamInstallBackend.swift`.

Evidence: SteamPerformanceDiagnosticsTests (concurrent totals, shared collector, retained reads, checksum separation and actual HTTP); SteamMacInstallTests.testMacDiagnosticsIncludeNestedPreparationAndValidationWork; original/final raw data above.

- **Covered:** Add lightweight counters and timings: network transfer, session creations, Adler-32 and SHA bytes/time (separately),   content bytes reread, checkpoints, fsyncs (file and directory), directory walks, progress callbacks, preparation and final   validation.
- **Covered:** Wire counters through `LiveSteamInstallBackend.download` (`SteamInstallBackend.swift:33-66`), which creates a new   `DownloadEngine` for each depot.
- **Covered:** Keep diagnostics out of the ordinary UI. Never log credentials.
- **Covered:** Record baselines for a large-file fixture and a many-small-files fixture. Measure a real installation separately when one is   available.

### Step 2

Source: `CDN.swift; SteamInstallBackend.swift`.

Evidence: CDNTransportTests (all 13 tests), CDNTransportBenchmarkTests.testHTTPConnectionReuseIfRequested; shared pool configuration and cancellation independence.

- **Covered:** Replace per-request `URLSession` creation with a shared, injectable CDN transport. Create it once per download in   `LiveSteamInstallBackend` (or hold it statically), not once per depot engine.
- **Covered:** Keep ephemeral configuration, no cookies or cache, request timeouts, cancellation and server failover.
- **Covered:** Set `httpMaximumConnectionsPerHost` to at least the in-flight chunk budget, or confirm that the CDN multiplexes over HTTP/2.   `ArtworkLoader.swift:176` is the existing shared-session example.
- **Covered:** Cancelling one request must not invalidate other transfers.
- **Covered:** Test session reuse, concurrent requests, cancellation, timeouts and retries.

### Step 3

Source: `CDN.swift; ResumableDepotDownload.swift`.

Evidence: CDNTransportTests.testCorruptPlaintextResponseRetriesBeforeWriterCommit / testCorruptPlaintextResponsesExhaustRetryBudget; DownloadResumeTests.testZlibZeroSeedMatchesKnownSteamVectorsIncludingEmpty, testVersionOneJournalKeepsValidIndicesAndRechecksCorruption, testChangedFileManifestAtSameGIDRejectsCheckpoint, testInvalidChunkRangesRejectedBeforeFetching, testWriterRejectsIncomingLengthBeforeWriting.

- **Covered:** Keep one validation inside the chunk-fetch retry (`CDNClient.fetchChunk`), so corrupt responses still retry. Remove the checks   at `ResumableDepotDownload.swift:55` and `:269`.
- **Covered:** Replace the Adler-32 loop with zlib's `adler32`. First prove with a test vector that `adler32(0, …)` gives the same result as   Steam's zero-seed variant.
- **Covered:** Keep length, offset, range and write-error checks.
- **Covered:** Replace per-chunk SHA-256 journal entries with completed chunk indices tied to the pinned file manifest.
- **Covered:** When resuming a partial file, validate retained chunks with `chunk.validate` (as `restore` does already).
- **Covered:** Version the journal. Version 1 journals migrate by keeping their chunk indices; `restore` rechecks each retained chunk. Never   discard usable downloads only because the format is old.
- **Covered:** Test corrupt responses, invalid ranges, damaged retained chunks, changed manifests and version 1 journals.

### Step 4

Source: `ResumableDepotDownload.swift; DownloadWorkspace.swift`.

Evidence: DownloadResumeTests.testFreshCompletionTrustsChunksAndExplicitVerificationRejectsBadFileDigest, testFinishUsesOneFileSyncAndNeverWritesDisposableJournal, testPublicationFailuresKeepOldTargetOrCompleteValidatedNewTarget, testENOSPCWriteDoesNotMarkFailedChunkCompleted, testFailedRenamePreservesOldTargetAndCheckpointForRetry, testCancelledFinishDoesNotPublishAndCheckpointRemainsUsable.

- **Covered:** Replace `finish()`'s full-file hash with checks that every expected chunk completed and the file size matches.
- **Covered:** Keep executable permissions, atomic replacement and durability ordering.
- **Covered:** Record completion only after the file is published.
- **Covered:** Test missing chunks, short files, failed writes, failed renames and cancellation during finalization.

### Step 5

Source: `ResumableDepotDownload.swift; DownloadWorkspace.swift`.

Evidence: DownloadResumeTests.testCheckpointByteThresholdIs128MiBAndFinalChunkDefersToFinish (frozen clock), testCheckpointClockUsesExactlyFiveSecondsAndSkipsIdleFlush, testCheckpointTimeThresholdIsFiveSeconds (real clock), testAtomicJournalReplacementSyncsOneDirectory, testCancelledTaskCanCheckpointIncompleteWork, testCheckpointFailuresBeforeAndAfterEveryBoundaryNeverRetainMissingBytes, testKilledChildResumesDurableReceiptsAndOnlyCheckpointedChunks.

- **Covered:** Change checkpoint thresholds from **16 MiB / 1 s** to **128 MiB / 5 s**, whichever comes first.
- **Covered:** Checkpoint on orderly pause and cancellation.
- **Covered:** `finish()` syncs the file once (after `fchmod`), renames it, then removes the journal if one exists. It never writes a journal   it is about to delete.
- **Covered:** `replace()` syncs a directory once when source and destination are the same directory.
- **Covered:** Keep ordering: persist downloaded bytes before a journal claims them.
- **Covered:** Test interruption before and after each persistence boundary with injected failures.

### Step 6

Source: `DownloadCompletionReceipt.swift; ResumableDepotDownload.swift; DownloadWorkspace.swift`.

Evidence: DownloadResumeTests receipt cadence/atomic flush, changed metadata/replacement/copied receipts, coarse timestamp limitation/full detection, excluded backups, old/large receipts, same-GID manifest mismatch, subset context and cleanup tests; killed-child proof below.

- **Covered:** Store versioned receipts in the game folder under `.gn-download/`, **one receipt file per depot manifest** (not per game   file). Write it on the checkpoint cadence.
- **Covered:** Each entry binds the relative path, pinned manifest, size, file identity and timestamps.
- **Covered:** Skip hashing completed files whose entry and metadata still match.
- **Covered:** Fully verify a file when its entry is missing, incompatible or mismatched; then refresh its entry or download it again.
- **Covered:** Keep checking retained chunks in incomplete files.
- **Covered:** Remove the leftover `.gn-download/` state that is not needed after the install finishes. It is never cleaned up today, and   `rejectLinks` and `GamesStorage` both walk it.
- **Covered:** Test changed size or timestamps, replaced files, copied or stale receipts, older installations and filesystems with coarse   timestamps.

### Step 7

Source: `SteamInstaller.swift; SteamInstallBackend.swift; InstallQueue.swift`.

Evidence: SteamInstallerTests.testRestartedStagesReuseReceiptsIncludingLegitimateOrigFiles, testRepairInspectsOlderInstallOnceAndDownloadsOnlyInvalidFiles, testExplicitRepairIgnoresMatchingReceipts, testPreparedStagesHashOnlyMappedBackupsAndRemoveTheirReceiptTrust, testInterruptedBackupCopyRecoversFromIntactOriginalBeforeStagingReceipt, testFailedOrInvalidUnpackingDoesNotReplaceOriginalAndCanResumeBeforeReceipt; SteamMacInstallTests unsigned/signed stage restart and interrupted original-copy tests; InstallQueueTests stage/runtime restart tests; full Epic/GOG/app suites.

- **Covered:** Make Steam's `verifyOriginals` use the step 6 receipts by default: a file whose metadata matches its receipt is not hashed.   The `.verifyOriginals` stage, `prepare` and `validate` then cost only metadata lookups.
- **Covered:** Keep the `.verifyOriginals` stage. It stays the restart-safe proof that the download finished: a mismatch still sends the job   back to download (`InstallQueue.swift:362`).
- **Covered:** Repair uses a full mode that ignores receipts. It checks once, then downloads **only the files that failed** (pass the   invalid set to the download instead of letting it hash every file again), and refreshes their receipts.
- **Covered:** Backups and prepared files (`.orig`, Mac originals) have no receipts and are hashed as today. These are few files.
- **Covered:** Keep executable compatibility checks, preparation receipts and Mac signing checks.
- **Covered:** Test restart at each stage, interrupted `.orig` creation, damaged backups, Windows executable preparation, Mac signing, and   unchanged GOG/Epic behavior.

### Step 8

Source: `SteamPreparationPaths.swift; Prepare.swift; PrepareMac.swift; SteamInstaller.swift; SteamPrerequisites.swift; SteamUnpacking.swift`.

Evidence: Confirmed write inventory below; SteamPreparationPathsTests; SteamInstallerTests manifest-only discovery, linked leaves/parents, replaced installation/workspace and interrupted copy tests; SteamMacInstallTests.testMacManifestDiscoveryPreservesUnrelatedLibraryAndFrameworkLinks, testMacSigningRechecksInstallationAfterAwait, testMacSigningRejectsManifestSealSymlinkBeforeInvokingSigner; InstallQueueTests.testStorageRejectsUnownedFoldersWrongTokenAndEscapingLocation.

- **Covered:** List every preparation write destination.
- **Covered:** Replace repeated recursive walks (including the one per executable at `SteamInstaller.swift:113`) with checks of the source,   destination and parent paths involved.
- **Covered:** Keep destination containment and installation ownership checks.
- **Covered:** Check once per uninterrupted operation; check again after a restart or interruption.
- **Covered:** Keep required Mac framework symlinks and reject write paths that escape the folder.
- **Covered:** Test linked parents, replaced destinations, legitimate Mac links and ownership mismatches.

### Step 9

Source: `ResumableDepotDownload.swift; InstallQueue.swift (InstallProgressRelay)`.

Evidence: DownloadSchedulingTests.testOverlapsFilesWithGlobalEightChunkAndWriterBound, testLargeFileAndSmallFilesShareEightSlots, testFailureAndCancellationCheckpointEveryOpenFileBeforeResume, testCancellationDrainsAllFilesAndReleasesDestinationLease; InstallProgressRelayTests bounded burst/drain; default remains 8 and measured results above.

- **Covered:** Preferred design: one ordered queue of chunks across all files, with **eight chunks in flight in total**. Each file has its   own writer and journal and is finished when its last chunk lands. This keeps at most a few files open and removes the small/large   split.
- **Not selected; preferred global eight-chunk design implemented:** Alternative if that is too large: up to **four files of 16 MiB or less** at a time, sharing the same eight-chunk budget.
- **Covered:** One destination lease for all workers.
- **Covered:** Create symlinks only after all file writes complete.
- **Covered:** Progress stays monotonic. Drain workers before pause or cancellation completes.
- **Covered:** Test concurrency limits, shared directories, failures, cancellation, bounded memory and accurate progress.

### Step 10

Source: `SteamInstallPlan.swift; SteamInstaller.swift; InstallQueue.swift; GamesStorage.swift; InstallSpace.swift; CrossOverGameBottles.swift; SteamPrerequisites.swift; SteamUnpacking.swift`.

Evidence: SteamInstallerTests space budget, remaining reservation, authoritative selected repair gate, phase close, legacy plan and overflow tests; InstallQueueTests live allocation, late preparation callback, restart/legacy and subset-final-counter tests; GamesStorageTests; InstallSpaceTests.testChecksActualDestinationAncestorAndRejectsLowSpaceAndOverflow; repair clarification below.

- **Covered:** Remove `2 × installed + largest + 256 MiB`.
- **Covered:** Peak extra space = installed content + backups of files that preparation may change (executables and API DLLs; copies may not   be clones on HFS+) + **256 MiB**. Download partials count as installed content because they are renamed into place.
- **Clarified; literal assertion is false under retained atomic replacement (see below):** Repair: old and new content overlap only for the prepared files, because repair downloads originals to their backup paths.
- **Covered:** Keep the reservation separate from transfer progress (`InstallQueue.swift:282`).
- **Covered:** Check the correct volume for game content versus runtime storage.
- **Covered:** Unfinished older jobs keep their stored, larger estimate. That is safe, so do not recalculate them.
- **Covered:** Test fresh installs, resume, repair, multiple queued jobs, low disk space and arithmetic overflow.

### Step 11

Source: `Final raw JSON and this result document; tests above`.

Evidence: Final required suites, killed-child proof, recovery/repair/display map and measured regressions below; final whole-branch review approved revision `2ba75aa` with no Critical or Important findings.

- **Covered:** Compare baseline and final counters: content rereads, checksum work, syncs, session creations, callbacks and elapsed time.
- **Covered:** Exercise pause/resume, forced termination, network failure, disk-full failure and preparation recovery.
- **Covered:** Confirm that explicit repair still finds and fixes corruption.
- **Covered:** Confirm that displayed progress and reservations match the new behavior.
- **Covered:** Report measured improvements and any workloads that got slower.

## Confirmed preparation write inventory

Checked against final Prepare.swift, PrepareMac.swift, SteamInstaller.swift, SteamPrerequisites.swift, SteamUnpacking.swift, StatsGen.swift and SteamSettingsINI.swift. Each atomic file write also uses a temporary file in its checked destination parent.

| Operation | Writes, removals and chmod | Authorization / source checks |
| --- | --- | --- |
| Windows executable unpack | Manifest `.exe.orig` copy; atomic replacement of manifest `.exe` | Both file leaves and all parents; same installation identity across runtime await; owned GameBottle; original backup digest rechecked; PE architecture/SteamStub checks retained |
| Windows API replacement | Manifest API DLL `.orig` copy; atomic API DLL replacement | DLL/backup leaves and all parents; bundled DLL SHA-256/architecture validation retained |
| Windows markers | Remove root `.steam_dll_restored`; write `orig_dll_path.txt`; create `.steam_dll_replaced` | Every leaf checked; unexpected directories or links cannot be recursively removed or followed |
| Interfaces | API parent `steam_interfaces.txt`; settings `steam_interfaces.txt`; create settings directory | Original input and both destinations, including every parent; manual configuration remains when no interfaces can be extracted |
| Settings | Adjacent `steam_appid.txt`; settings `steam_appid.txt`, `depots.txt` removal/recreation, `configs.user.ini`, `configs.app.ini`, `configs.main.ini`, `supported_languages.txt` | Every leaf and parent checked in the uninterrupted settings operation |
| Optional achievements | Settings `achievements.json`, `stats.json`, `achievement_name_to_block.json` and config directory | All three leaves checked before StatsAchievementsGenerator; current SteamInstaller metadata still supplies no schema |
| Offline connectivity | Windows API parent/settings `configs.main.ini`; Mac `.playden-steam/steam_settings/configs.main.ini` | Destination and all parents checked |
| Runtime overlay | Windows API parent/settings `configs.overlay.ini`; Mac `.playden-steam/steam_settings/configs.overlay.ini` | Entire ancestor chain and leaf checked; unchanged values still avoid rewrites |
| Mac libraries | Manifest library `.playden-originals/<relative path>` copy; atomic API dylib replacement; chmod 0755 | Source/backup/destination and every parent; bundled digest and original Mach-O checks retained |
| Mac settings | `.playden-steam` directory and settings/interface/appid files above | Contained settings anchor; logical `libsteam_api.dylib` anchor itself is not written |
| Mac executable modes | Manifest executable-flag or Contents/MacOS regular files chmod 0755 | Each file and parents; chmod skipped when already 0755, preserving receipts |
| Mac signing originals | `.playden-originals/<bundle>/Contents/MacOS/<file>` and `.playden-originals/<bundle>/Contents/_CodeSignature/CodeResources` | Source/backup leaves and every parent; current receipt mapping of direct executable files preserved |
| Mac signing | Info.plist-selected main executable and `Contents/_CodeSignature/CodeResources` in each signed app | Valid contained manifest-selected executable; source plist and all relevant paths checked before/after awaited signer; no `--deep`, no recursive framework authorization |
| Emulator saves | External configured `<emulatorSaves>/<appID>` directory creation | Declared external storage destination and entire parent chain checked, including existing app-ID leaf; never derived from game content |
| Prerequisites | Create UUID-owned temp root mode 0700, selected prerequisite file parents and copies; remove owned temp root on exit | Manifest-selected original source verification plus source/target path checks; temp root identity retained; copied manifest verified; runtime owns bottle changes; recheck after each await; do not remove a replaced temp root |
| Unpacking workspace | Create UUID-owned temp root mode 0700; copy verified bundled `Steamless` tool directory; copy Plugins `Steamless.API.dll` and `SharpDisasm.dll` alongside CLI; copy `game.exe`; runtime writes `game.exe.unpacked.exe`; remove owned temp root | Validated storage parents; fresh private workspace before synchronous tool/input copies; same workspace and private regular output checked after runtime await; tool checksums and output PE checks retained; do not remove a replaced temp root |
| Partial original-copy recovery | Remove incomplete Windows `.orig` or Mac `.playden-originals/<path>` only after full source verification | New scoped leaf/parent/root check supplements existing full pinned source inspection; invalid source still blocks deletion |
| Standalone restore | Atomic API DLL destination replacement; remove `.steam_dll_replaced`; create `.steam_dll_restored` | Scoped backup, destination, mapping and marker paths; existing discovery fallback preserved |
| Verification bookkeeping | Existing `.gn-download` receipts/checkpoints/lock writes and cleanup | Unchanged DownloadWorkspace descriptor-relative protections and task 7 verification/repair behavior |

Final seal correction: the actual `Contents/_CodeSignature/CodeResources` signer destination is checked unconditionally before and after signing, even when the manifest marks it as a symlink and therefore excludes it from the regular signed-file list. The manifest-seal regression proves the signer is not invoked and the linked target is unchanged. Legitimate unrelated framework links remain allowed.

## Repair overlap and conservative limits

The original plan sentence “old and new content overlap only for the prepared files” is retained as historical intent but is physically false for the existing atomic replacement algorithm. Invalid ordinary targets remain until replacement publication too. The accepted implementation preserves old targets and gates the entire selected invalid subset plus preparation backups/headroom, subtracting only trustworthy materialized replacement-partial allocation. It assumes no old extents are reclaimed, which remains safe with APFS snapshots/clones. A provisional queued repair estimate may increase after full inspection; it never authorizes transfer. The final phase switches to preparation-only reservation before awaiting capacity, so late transfer allocation cannot erase it.

Fresh installs reserve installed content + potential preparation backups + 256 MiB. Renamed partials count as installed content. Existing unfinished older jobs keep their stored larger estimates; new repair jobs can use current budgeting without rewriting the original plan. Download bytes/rates and allocation credit remain independent. Runtime/temp/bottle writes check their actual destination volumes. Unknown bootstrap/prerequisite expansion has no declared size; it receives 256 MiB headroom and retains ENOSPC/error recovery. This is a conservative guard, not a new runtime expansion estimator.

Ordinary metadata receipts deliberately cannot detect content changes that preserve file identity, size and timestamps. Full explicit repair ignores receipts. Prepared originals/backups remain fully hashed. Path guards preserve the existing synchronous check-before-write model with rechecks after awaits; they do not claim atomic exclusion against an external process racing codesign or an individual filesystem call.

## Final validation and recovery evidence

All commands reached their terminal status. The package build products were cleaned first with `swift package --package-path Packages/SteamKit clean` and `swift package --package-path Packages/PlaydenKit clean`, preserving dependency checkouts/resolutions. Required commands ran sequentially. Each required suite passed on its first final run. The optional HTTP benchmark’s failed exact-socket assertion and one focused corrected recheck are disclosed above; both datasets/logs are retained. The separate earlier RED runs below intentionally reproduced the targeted bugs.

| Exact required command | Exit | Result |
| --- | ---: | --- |
| `swift test --package-path Packages/SteamKit` | 0 | 144 XCTest tests, 3 opt-in skips, 0 failures |
| `swift test --package-path Packages/PlaydenKit` | 0 | 492 XCTest tests, 9 opt-in skips, 0 failures; 5 Swift Testing tests passed |
| `./scripts/test.sh` | 0 | Steam 144/3 skips; Epic 26/2; GOG 41/2; Playden 492/9 + 5; xcodegen succeeded; 267 app tests passed; `TEST SUCCEEDED` |

At validation time, detailed terminal logs and `terminal-statuses.json` were collected in `.superpowers/sdd/2026-10-12-faster-steam-installations/task-11-logs/` for review. That ignored SDD workspace is expected to be cleaned up afterward; original `/tmp/task11-*.log` files and `/tmp/task11-terminal-statuses.json` remain available until temporary-file cleanup. The full app result bundle is `DerivedData/Logs/Test/Test-Playden-2026.10.12_15-09-11-+0200.xcresult`. The tracked test names, numeric results and raw measurements in this document remain useful if ignored scratch/build artifacts are cleaned.

Compiler output was not pristine: existing SteamAuth/DownloadResumeTests Sendable conversion warnings, SignInRelay/NativeRunner/RuntimeProcessInspector C-string deprecations, Homebrew xz/zstd deployment-target warnings, bundled-library re-sign notices, and AppIntents metadata notices remain. App tests also emitted unavailable OrbStack-volume capacity and expected connection diagnostics; they passed. No warning was suppressed. The previously documented `LibrarySyncTests.testThrottledRefreshReachesTheStalestMetadataFirst` race did not reproduce in either final Playden execution. Live account/CDN, optional real game/runtime probes and performance tests without their opt-in variables remain skipped in ordinary suites. Fixed filesystem and loopback performance tests ran separately with explicit opt-in variables.

| Requirement | Current proof and outcome |
| --- | --- |
| Real forced termination and resumed durable data | `DownloadResumeTests.testKilledChildResumesDurableReceiptsAndOnlyCheckpointedChunks` explicitly spawns one disposable xctest child in a UUID temporary directory. Child publishes a 16-byte completed file and depot receipt, checkpoints the first 5 bytes of another file, writes 6 additional uncheckpointed bytes, then signals readiness. Parent sends SIGKILL only to its child's PID, waits, and asserts uncaught signal 9. Parent inspects the receipt, physical 11-byte partial and journal `[0]`, opens a fresh downloader, fetches offsets `[5, 11]` (11 bytes), rereads only the durable 5 bytes, and verifies final 32-byte progress/content. Focused run PID 77584; clean full Steam run PID 1893; final script run PID 26446. |
| Pause/cancel and network recovery | `DownloadSchedulingTests.testFailureAndCancellationCheckpointEveryOpenFileBeforeResume` covers both injected network failure and cancellation across overlapping files, all workers drained, lease released, checkpoint/receipt retention, four missing bytes fetched and delayed symlink creation. `testCancellationDrainsAllFilesAndReleasesDestinationLease` and `InstallQueueTests.testGameplayPauseWaitsForDownloadWorkerToFinish` cover lifecycle ordering; queue pause/restart tests retain pins and completed stages. CDN tests cover real loopback timeout/failover/cancellation, exhausted retries and corrupt responses. |
| Disk-full/write/publication recovery | `DownloadResumeTests.testENOSPCWriteDoesNotMarkFailedChunkCompleted`, `testFailedRenamePreservesOldTargetAndCheckpointForRetry`, boundary-failure tests, missing-chunk/truncated-file tests and cancellation before/after publication prove retained valid content and safe retry. ENOSPC is deterministically injected at the real write boundary; no user volume is filled. |
| Preparation interrupted before receipt | `SteamInstallerTests.testInterruptedBackupCopyRecoversFromIntactOriginalBeforeStagingReceipt`, `testFailedOrInvalidUnpackingDoesNotReplaceOriginalAndCanResumeBeforeReceipt`, SteamStub replay/repair tests, and `SteamMacInstallTests.testInterruptedMacOriginalCopyRecoversBeforePreparationReceipt` cover recovery. Queue stage/runtime restart tests preserve completed work and re-establish prerequisites when needed. |
| Explicit repair detects and restores corruption | `SteamInstallerTests.testRepairInspectsOlderInstallOnceAndDownloadsOnlyInvalidFiles` hashes both originals once, repairs only the corrupted 128 KiB asset, verifies restored bytes and refreshed receipts. `testPreparedStagesHashOnlyMappedBackupsAndRemoveTheirReceiptTrust` and repair restoration tests preserve strict backup validation. `DownloadResumeTests.testCoarseTimestampModelDocumentsMetadataPreservingCorruptionAndFullDetection` proves full mode catches corruption hidden by matching metadata receipts. |
| Ordinary stage checks remain restart-safe | `SteamInstallerTests.testRestartedStagesReuseReceiptsIncludingLegitimateOrigFiles`, signed/unsigned Mac restart tests, and unchanged `.verifyOriginals` checkpoint/invalidation logic prove receipt-assisted normal paths still return to download on mismatch. Prepared backups use full hashes and executable/Mach-O/signing checks remain active. |
| Display counters and reservations | New `InstallQueueTests.testSteamSubsetRepairFinishesWithCoherentDisplayedAndPersistedCounters` reproduces the actual queue/relay with a 2-byte repair in an 8-byte installation: old behavior persisted 8/2; final snapshot and catalog both store 2/2. Live allocation tests distinguish downloaded/written bytes from allocation credit; late repair callbacks preserve preparation capacity and offer reservations after drain; resumed older jobs retain conservative stored estimates. `GamesStorageTests`, `InstallSpaceTests` and source/runtime guards cover correct volumes, multiple jobs, low space and overflow. This is model/snapshot/persistence evidence, not a visual manual UI probe. |
| Catalog verification while save fails | `InstallQueueTests.testDownloadVerificationProgressSaveFailureIsAdvisoryAndRetries` delivers verification with valid transfer counters while the rejecting database trigger is installed, observes it in the in-memory transfer snapshot with the durable record still at zero, then removes the trigger and confirms subsequent persistence. No new production change was needed for this gate. |
| Unconditional signing write path | `SteamMacInstallTests.testMacSigningRejectsManifestSealSymlinkBeforeInvokingSigner` uses a legal pinned seal symlink to another fixture file. RED invoked the signer and changed its target from 13 to 6 bytes; GREEN rejects before invocation and preserves the target. The one-line guard covers `CodeResources` independently of manifest regular-file filtering. |
| Cadence isolation | Internal monotonic clock injection freezes time in the 127/128 MiB byte test; an exact 4.999/5-second virtual-clock test checks the time boundary and idle flush. Production defaults and thresholds stay 128 MiB / 5 seconds. The existing real 5.1-second integration test remains and passed. |

After required full-suite completion, the only production-source edit was an explanatory CDN comment: connection capacity 16 remains above the scheduler's actual eight-chunk budget. The optional benchmark assertion correction then passed its single focused release recheck; ordinary suites skip that opt-in benchmark. No production behavior changed after the required suite runs. The final test cleanup below was validated separately; the retained full-suite runs predate those modified tests.

## Final review and focused test cleanup

Final whole-branch review approved `3c1b585..2ba75aa`: ready to merge, with no Critical or Important findings. It read the full production/test/documentation diff and parsed all 13 raw JSON artifacts, checking 1,052 displayed phase-metric cells including the 272 final comparison cells and all 20 final phase/total elapsed comparisons. The review accepted the step-10 atomic-replacement overlap clarification and the optional HTTP benchmark correction; the original failed benchmark dataset/log and corrected dataset remain distinct and unchanged.

The two Minor findings received localized test cleanup. `CDNTransportTests.testSequentialRequestsAcrossDepotsReuseConnection` now runs 16 sequential requests alternating two depots, checks every response, exactly one session, 16 requests and 112 transferred bytes, and proves real reuse with fewer accepted sockets than requests while allowing Foundation's spare sockets. Unrelated exact socket-count assertions were removed from cancellation, privacy, warmed-session, retry-exhaustion and multiple-engine tests; their response, request, session, cancellation, validation and retry assertions remain. Privacy and warmed-session tests now explicitly check two served requests. `SteamMacInstallTests.testMacSigningRejectsManifestSealSymlinkBeforeInvokingSigner` now matches `SteamError.prepare` and the exact linked/unexpected-file-type rejection at the canonical `CodeResources` path, retaining the uncalled signer and unchanged linked target assertions.

| Exact cleanup command | Exit | Result and log |
| --- | ---: | --- |
| `swift test --package-path Packages/SteamKit --filter CDNTransportTests` | 0 | All 13 class tests, 0 failures; `/tmp/final-steam-fix-cdn.log` |
| `swift test --package-path Packages/PlaydenKit --filter SteamMacInstallTests.testMacSigningRejectsManifestSealSymlinkBeforeInvokingSigner` | 0 | 1 test, 0 failures; `/tmp/final-steam-fix-seal.log` |

The seal command initially exited 1 because the new expected path used Foundation's `/var` spelling while the guard reports `/private/var`. The expected path now uses `SteamPreparationPaths.root` and still matches the exact rejection message and leaf. This test-expectation error is retained in `/tmp/final-steam-fix-seal-path-mismatch.log`; it was not a production failure. The CDN class contains 13 tests in both the reviewed and cleanup revisions; the separate optional benchmark test is not part of that class. No full suites or benchmarks were rerun for this test/documentation cleanup.

Earlier deferred concerns are addressed: verification progress is tested while catalog writes fail; diagnostic closure warnings are corrected; virtual-clock cadence tests retain the real-clock integration test; and the signer destination is authorized independently of manifest regular-file filtering. Existing environment/compiler warnings remain disclosed. Review limits remain the offline/warm fixtures, unavailable live CDN/GTA V recovery, untested physical power loss, synchronous filesystem race model, undeclared runtime expansion sizing and unrelated LibrarySync scheduling race; no broader guarantee or universal speedup is claimed. This cleanup changes only tests and final status documentation, with no new benchmarks or production changes. Its scoped re-review is separate from the approved whole-branch revision.
