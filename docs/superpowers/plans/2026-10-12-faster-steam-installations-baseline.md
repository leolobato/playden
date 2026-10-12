# Steam installation performance baseline — 2026-10-12

Baseline for step 1 of [the installation plan](2026-10-12-faster-steam-installations.md), based on `ad14c56` plus opt-in instrumentation. No downloader optimization is included. The fixed fixture command is intended to be reused after later steps.

## Repeat the measurement

```sh
scripts/benchmark-steam-install.sh /private/tmp /tmp/steam-after-apfs.json 3
scripts/benchmark-steam-install.sh /Volumes/VM /tmp/steam-after-hfs.json 3
```

The first argument must be an existing directory on the target volume. The command runs a **release** Swift test, constructs unique `.playden-install-benchmark-<UUID>` directories beneath it, and removes only those directories on exit. It neither reads a live game directory nor opens a catalog. JSON output is opt-in and contains fixed workload names and numeric values; no paths, request URLs, identifiers or credentials are exported. Regular package test runs skip the benchmark unless `PLAYDEN_STEAM_BENCHMARK_ROOT` is set. Direct invocation uses `swift test -c release --package-path Packages/PlaydenKit --filter SteamInstallationBenchmarkTests.testInstallationFixtures`, with `PLAYDEN_STEAM_BENCHMARK_ROOT`, `PLAYDEN_STEAM_BENCHMARK_OUTPUT`, and `PLAYDEN_STEAM_BENCHMARK_ITERATIONS` set explicitly.

Measured host: Mac17,9, 48 GiB RAM, macOS 26.6.2, Apple Swift 6.2.4, arm64. `/private/tmp` is on the internal SSD/APFS root volume; `/Volumes/VM` is an external USB/Journaled HFS+ volume. Three fresh repetitions were run per fixture per volume, alternating large and small within each volume, without concurrent builds or other benchmark commands. Cache state was not reset; filesystem and bundled-asset caches are therefore warm after the first sample. Samples use the same data, release configuration, concurrency and latency. Compare per-volume medians; they are observations, not hardware-independent limits.

| Fixture | Content | Files / chunks | Original bytes |
| --- | --- | --- | ---: |
| large-file | 128 MiB archive, 128 × 1 MiB chunks of `0x5a`, plus a 1 KiB PE executable and a 1 KiB Steam API DLL | 3 / 130 | 134219776 |
| many-small-files | 512 × 16 KiB files of `0x5a` in 16 directories, plus the same executable and DLL | 514 / 514 | 8390656 |

Each workload has two depots, one shared collector and chunk concurrency 8. Every manifest file has a whole-file SHA-1 and every chunk has Steam's zero-seeded Adler-32. A test backend supplies plaintext from memory after a requested 2 ms sleep per fetch. It applies `chunk.validate` at the fetch boundary, matching the real CDN's current validation contract, before the existing writer validations. `simulatedFetch` counts actual scheduled sleep/fetch time separately from hashing. The fixture does not perform HTTP, TLS, decrypt or decompress, so **`networkTransfer` and `sessionCreation` are zero in every phase of every recorded sample**; these zeros are not evidence of live CDN performance or connection reuse. A bounded loopback HTTP regression separately verifies real URLSession creation, response-body bytes and HTTP failure measurement.

The phase sequence mirrors the current install pipeline: `download` → `verifyOriginals` → `postInstall` → `validate`. Preparation replaces the fixture DLL with the actual bundled GBE asset, writes settings, retains the original, hashes assets and scans directories. Final validation checks both retained originals and the staged DLL. The separate original-verification phase exposes all three post-download whole-game passes. InstallQueue/catalog persistence, CM authentication/key retrieval, runtime prerequisites, SteamStub execution and Mac codesigning are excluded from these fixed Windows fixtures. Focused regressions cover nested Mac preparation/validation and SteamStub tool hashes. There is no active Playden process/account installation available; a real installation measurement is inapplicable and no game/catalog was touched.

## Elapsed time

Each cell lists samples in repetition order, then the median, in milliseconds. Timing begins after fixture construction/plan resolution. The first phase excludes benchmark build time; subsequent phase boundaries include the preceding numeric snapshot overhead.

| Volume / fixture | Download samples → median | Original verification samples → median | Preparation samples → median | Final validation samples → median |
| --- | --- | --- | --- | --- |
| APFS / large-file | 610.99, 614.27, 510.31 → **610.99** | 55.79, 49.91, 49.15 → **49.91** | 101.08, 73.63, 79.29 → **79.29** | 58.48, 53.47, 57.72 → **57.72** |
| APFS / many-small-files | 2364.59, 2567.25, 2598.42 → **2567.25** | 37.55, 52.16, 52.25 → **52.16** | 99.02, 82.02, 83.74 → **83.74** | 61.99, 53.88, 51.99 → **53.88** |
| HFS+ / large-file | 3530.84, 3481.07, 3484.86 → **3484.86** | 50.56, 50.42, 48.91 → **50.42** | 270.99, 254.74, 244.66 → **254.74** | 53.61, 53.14, 53.00 → **53.14** |
| HFS+ / many-small-files | 2972.42, 2649.65, 2934.05 → **2934.05** | 51.73, 47.30, 50.71 → **50.71** | 262.79, 320.05, 285.91 → **285.91** | 52.09, 58.58, 60.33 → **58.58** |

## Metric interpretation

A collector is optional, defaults to nil, and does not print anything or alter normal UI progress. When enabled it takes monotonic timestamps and aggregates under one short-held NSLock. It releases the lock before callbacks and measured work. Snapshots are cumulative; the benchmark JSON exports **deltas for each named phase**, so a preparation counter contains only preparation work, and validation contains only validation work.

Each metric contains `count`, `bytes`, and `nanoseconds`. Durations are **summed operation durations** and can exceed wall time when chunks run concurrently. Timings for containing operations also include their children: checkpoint includes syncs/writes/walks, file validation includes reads/hashes/callbacks, preparation includes emulator preparation and verification, and final validation includes verification. Do not add all metric durations together or subtract concurrent hashing totals from wall time to infer unmeasured costs.

| Metric | What it records |
| --- | --- |
| `networkTransfer` | Each CDN `URLSession.data(for:)` attempt, including status/transport/cancellation errors. Bytes are complete response-body bytes, before decrypt/decompress, including non-200 bodies. Transport failures have zero bytes because this API does not expose partial bodies. Excludes session construction and CM/WebAPI calls. |
| `sessionCreation` | URLSession construction count/time; retained once-per-request behavior in this baseline. |
| `adler32`, `sha1`, `sha256` | Separate algorithm bytes/time. SHA-256 includes journal content fingerprints, path keys, retained-chunk hashes, bundled asset/tool integrity and staged-file hashes. Hash update/finalize calls are individually counted; finalization can have zero bytes. |
| `contentRead` | Actual bytes returned by explicit file-content reads, including assembled-file/resume rereads, PE inspection, interface extraction and bundled asset/tool reads. Counts EOF reads with zero bytes. Mapped reads count logical length, not physical drive I/O; their page faults may occur during the later hash. Excludes checkpoint JSON reads, implicit FileManager copies and external runtime I/O. |
| `fileWrite` | Chunk and checkpoint-journal write calls and supplied bytes/time. Includes journal bytes in addition to game content. Preparation settings/copies remain included in preparation elapsed time rather than in this download-write counter. |
| `checkpoint` | Nonempty checkpoint attempts/time, including encoding, journal write, fsyncs and path traversal. |
| `fileSync`, `directorySync` | File synchronization and directory fsync attempts/time, including unsupported directory fsync attempts handled by the existing code. |
| `directoryWalk` | Descriptor-relative parent traversal attempts and recursive SteamInstaller/SteamPreparer scans, including failures. This counts whole walk invocations, not visited entries. |
| `progressCallback` | Measured callback boundaries in the CDN, writer/verifier, installer and live backend. Nested callbacks are each counted/timed; this is not a count of unique UI updates. No-op callbacks also count. |
| `keyPreparation` | DownloadEngine's async depot-key preparation pass. Zero in the account-free fixture. |
| `fileValidation` | Whole-file validation attempts, including existing missing-file checks, assembled files and original verification. Includes failed/missing attempts. |
| `emulatorPreparation` | Nested SteamPreparer Windows/Mac work, including scanning, asset hashing, replacement and settings. |
| `preparation`, `finalValidation` | Full installer preparation/final-validation attempts/time, including their nested work and errors. |

Enable the same collector for live download, preparation and validation:

```swift
let diagnostics = SteamPerformanceDiagnostics()
let installer = SteamInstaller(game: game, account: account, diagnostics: diagnostics)
// Execute the installer stages using this instance.
let numericSnapshot = diagnostics.snapshot()
let data = try JSONEncoder().encode(numericSnapshot)
```

`LiveSteamInstallBackend.download` passes this one reference to its key-preparation engine and each per-depot DownloadEngine; DownloadEngine passes it into CDN and ResumableDepotDownload. A new collector isolates a new installation; repeated calls on one collector accumulate. Lower-level DownloadEngine, ResumableDepotDownload and SteamPreparer initializers also accept the optional collector. For phase reporting outside this benchmark, record snapshots at boundaries and subtract corresponding numeric fields.

## Phase diagnostics

These tables give the median for every active metric in each phase, independently by field. Cells are **count / bytes / summed milliseconds**. Field-wise medians are not necessarily all from the same sample. Raw sample values, including zero metrics, are retained in [APFS JSON](steam-install-baselines/2026-10-12-apfs.json) and [HFS+ JSON](steam-install-baselines/2026-10-12-hfs.json). `simulatedFetch` totals follow separately.

### download

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `adler32` | 390 / 402659328 / 1017.785 | 1542 / 25171968 / 112.724 | 390 / 402659328 / 987.584 | 1542 / 25171968 / 112.784 |
| `checkpoint` | 10 / 0 / 67.361 | 514 / 0 / 408.160 | 10 / 0 / 1995.845 | 514 / 0 / 852.469 |
| `contentRead` | 133 / 134219776 / 7.469 | 1028 / 8390656 / 6.916 | 133 / 134219776 / 7.597 | 1028 / 8390656 / 6.434 |
| `directorySync` | 26 / 0 / 0.017 | 2056 / 0 / 2.936 | 26 / 0 / 0.010 | 2056 / 0 / 1.541 |
| `directoryWalk` | 63 / 0 / 3.482 | 5656 / 0 / 396.273 | 63 / 0 / 3.269 | 5656 / 0 / 416.023 |
| `fileSync` | 23 / 0 / 59.820 | 1542 / 0 / 69.499 | 23 / 0 / 1988.403 | 1542 / 0 / 504.618 |
| `fileValidation` | 6 / 0 / 50.834 | 1028 / 0 / 98.208 | 6 / 0 / 50.194 | 1028 / 0 / 96.613 |
| `fileWrite` | 140 / 134251823 / 63.619 | 1028 / 8462941 / 41.638 | 140 / 134251823 / 1064.163 | 1028 / 8462941 / 16.556 |
| `progressCallback` | 290 / 0 / 0.224 | 6168 / 0 / 4.132 | 290 / 0 / 0.410 | 6168 / 0 / 3.810 |
| `sha1` | 136 / 134219776 / 43.110 | 1542 / 8390656 / 6.281 | 136 / 134219776 / 42.195 | 1542 / 8390656 / 6.279 |
| `sha256` | 136 / 134237204 / 45.200 | 1542 / 8531609 / 10.002 | 136 / 134237204 / 43.922 | 1542 / 8531609 / 9.963 |

### originalVerification

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `contentRead` | 133 / 134219776 / 7.285 | 1028 / 8390656 / 1.381 | 133 / 134219776 / 7.488 | 1028 / 8390656 / 1.864 |
| `directoryWalk` | 3 / 0 / 0.025 | 514 / 0 / 8.214 | 3 / 0 / 0.026 | 514 / 0 / 9.557 |
| `fileValidation` | 3 / 0 / 49.096 | 514 / 0 / 18.628 | 3 / 0 / 49.532 | 514 / 0 / 21.245 |
| `progressCallback` | 37 / 0 / 0.008 | 5147 / 0 / 0.459 | 37 / 0 / 0.008 | 5147 / 0 / 0.458 |
| `sha1` | 136 / 134219776 / 41.634 | 1542 / 8390656 / 2.800 | 136 / 134219776 / 41.457 | 1542 / 8390656 / 2.970 |

### preparation

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `contentRead` | 153 / 188417344 / 10.056 | 1048 / 62588224 / 2.828 | 153 / 188417344 / 8.997 | 1048 / 62588224 / 12.071 |
| `directoryWalk` | 6 / 0 / 1.145 | 517 / 0 / 24.194 | 6 / 0 / 0.910 | 517 / 0 / 27.188 |
| `emulatorPreparation` | 1 / 0 / 18.092 | 1 / 0 / 25.866 | 1 / 0 / 194.473 | 1 / 0 / 216.313 |
| `fileValidation` | 3 / 0 / 50.865 | 514 / 0 / 18.138 | 3 / 0 / 48.951 | 514 / 0 / 24.728 |
| `preparation` | 1 / 0 / 79.283 | 1 / 0 / 83.733 | 1 / 0 / 254.729 | 1 / 0 / 285.900 |
| `progressCallback` | 58 / 0 / 0.016 | 7212 / 0 / 0.926 | 58 / 0 / 0.014 | 7212 / 0 / 0.945 |
| `sha1` | 136 / 134219776 / 42.571 | 1542 / 8390656 / 2.823 | 136 / 134219776 / 41.470 | 1542 / 8390656 / 3.041 |
| `sha256` | 13 / 33694280 / 13.312 | 13 / 33694280 / 11.181 | 13 / 33694280 / 11.181 | 13 / 33694280 / 11.449 |

### validation

| Metric | APFS large | APFS small | HFS+ large | HFS+ small |
| --- | --- | --- | --- | --- |
| `contentRead` | 143 / 141526952 / 9.142 | 1038 / 15697832 / 2.249 | 143 / 141526952 / 8.013 | 1038 / 15697832 / 2.838 |
| `directoryWalk` | 4 / 0 / 0.273 | 515 / 0 / 10.255 | 4 / 0 / 0.276 | 515 / 0 / 10.565 |
| `fileValidation` | 3 / 0 / 51.959 | 514 / 0 / 18.809 | 3 / 0 / 48.612 | 514 / 0 / 21.953 |
| `finalValidation` | 1 / 0 / 57.715 | 1 / 0 / 53.869 | 1 / 0 / 53.139 | 1 / 0 / 58.569 |
| `progressCallback` | 58 / 0 / 0.017 | 7212 / 0 / 0.773 | 58 / 0 / 0.016 | 7212 / 0 / 0.753 |
| `sha1` | 136 / 134219776 / 42.885 | 1542 / 8390656 / 2.858 | 136 / 134219776 / 40.910 | 1542 / 8390656 / 2.837 |
| `sha256` | 8 / 7305128 / 2.245 | 8 / 7305128 / 2.223 | 8 / 7305128 / 2.234 | 8 / 7305128 / 2.270 |

### Simulated fetch (separate from real network)

| Volume / fixture | Calls | Bytes | Summed milliseconds, samples → median |
| --- | ---: | ---: | --- |
| APFS / large-file | 130 | 134219776 | 384.76, 374.61, 375.39 → **375.39** |
| APFS / many-small-files | 514 | 8390656 | 1477.14, 1482.89, 1503.08 → **1482.89** |
| HFS+ / large-file | 130 | 134219776 | 378.04, 362.47, 375.91 → **375.91** |
| HFS+ / many-small-files | 514 | 8390656 | 1492.81, 1514.63, 1484.18 → **1492.81** |

## Observations and limits

The baseline preserves three Adler passes per fresh chunk, SHA-256 journaling, the final assembled-file reread, and the three later whole-original verification passes. The many-small fixture pays per-file checkpoints/syncs/walks and serial per-file fetch latency; the large fixture uses chunk concurrency and byte-based checkpoints. HFS+ large-file elapsed time is substantially higher than APFS, while subsequent original reads are cached. The measurements identify hashing, content rereads, filesystem calls and stage costs separately without claiming simulated fetch time is real CDN time.

No timers alter chunk concurrency, checksum rules, checkpoint thresholds, durability or the preparation/repair contract in this step. Opt-in measurement overhead is included consistently in the baseline. Keep this dataset and simulated-fetch validation boundary unchanged for later comparisons; any new metadata/receipt path should be exercised by the same fixture stages and noted alongside the results. Connection reuse needs a separate HTTP/real-CDN measurement because this plaintext fixture creates no sessions. Large installations, cold caches, different external hardware and actual TLS/decompression can have different timing distributions.
