# Steam installation measurements after Step 2 — 2026-10-12

Step 2 shares one lazy, injectable ephemeral CDN transport across all chunks and depot engines in a live download. It keeps the request timeout at 30 seconds and resource timeout at 60 seconds, allows 16 HTTP connections per host (the current maximum in-flight chunk budget), disables cookies/cache, and preserves task cancellation, retry/failover and all validation/writer behavior. Key preparation creates no unused session. Default low-level callers share a static transport; a collector attached after session construction truthfully records zero new sessions.

## Real transport evidence

The socket fixture speaks HTTP/1.1 keep-alive on numeric loopback only and serves connections on independent workers. Ten focused regressions verify one connection across depot requests; 16 simultaneous requests with independent responses and one session; cancelled-request isolation and sibling connection reuse; request timeout recovery; no cookie/cache retention; failed-status failover; three-attempt retry exhaustion; cancellation without retry; an already-created static session without false creation counts; and key preparation followed by actual encrypted, decoded, checked, committed chunks through two depot engines. The synthetic AES key and payload are fixed fixture bytes. The routing adapter rewrites only synthetic CDN URLs to loopback; HTTP, URLSession, decryption/decompression, checksums, retries and filesystem writes stay real.

The release microbenchmark alternates per-request and shared transports, three fresh samples per mode, 64 sequential requests crossing two synthetic depot paths. The per-request mode uses a new real transport for each request, reproducing the former session lifetime; it is confined to test code. Timed batches run sequentially and exclude compilation.

```sh
PLAYDEN_STEAM_CDN_BENCHMARK_OUTPUT=/tmp/steam-step2-http.json swift test -c release --package-path Packages/SteamKit --filter CDNTransportBenchmarkTests.testHTTPConnectionReuseIfRequested
```

| Transport | Elapsed samples ms → median | Sessions / TCP connections per sample | Requests / body bytes per sample |
| --- | --- | ---: | ---: |
| per-request | 31.782, 20.523, 20.529 → **20.529** | 64 / 64 | 64 / 448 |
| shared | 11.464, 10.008, 10.109 → **10.109** | 1 / 1 | 64 / 448 |

Shared transport reduced median loopback elapsed time by 50.8% in this tiny workload. Connection/session evidence is direct; elapsed benefit is specific to local HTTP without TLS and seven-byte bodies. No live-CDN or whole-install speedup is inferred. Raw numeric samples: [HTTP JSON](steam-install-baselines/2026-10-12-step-2-http.json).

Actual session construction records `sessionCreation` once, under a lock that prevents concurrent first requests creating multiple sessions. `networkTransfer` starts after session construction and records each real URLSession attempt, including non-200 body bytes and zero complete-body bytes for timeout/cancellation/transport errors. Transport implementations own these metrics; an injected non-network transport must not claim real network work. The existing plaintext benchmark remains unchanged.

## Same installation fixtures, repeated

```sh
scripts/benchmark-steam-install.sh /private/tmp /tmp/steam-step2-apfs.json 3
scripts/benchmark-steam-install.sh /Volumes/VM /tmp/steam-step2-hfs.json 3
```

The runs used the exact [tracked baseline dataset and phase sequence](2026-10-12-faster-steam-installations-baseline.md), release mode, concurrency 8 and requested simulated fetch delay of 2 ms. APFS and external USB/Journaled HFS+ timed runs were sequential, following the HTTP batch, with no overlapping build/benchmark. Fresh UUID fixture directories were deleted; zero benchmark directories remained under either parent. No live game/catalog/account was accessed. The host remains Mac17,9 / 48 GiB / macOS 26.6.2 / Swift 6.2.4. Cache state was not reset.

Every metric count and byte total in every phase and corresponding repetition matches the baseline exactly. All samples still report zero `networkTransfer` and `sessionCreation`, so these plaintext timings provide no transport-effect evidence. The following medians show baseline → Step 2 and relative change, in milliseconds; variation reflects the unchanged filesystem/hash fixture and host/cache conditions.

| Volume / fixture | Download | Original verification | Preparation | Final validation |
| --- | --- | --- | --- | --- |
| APFS / large-file | 610.99 → 517.66 (-15.3%) | 49.91 → 49.36 (-1.1%) | 79.29 → 81.85 (+3.2%) | 57.72 → 52.85 (-8.4%) |
| APFS / many-small-files | 2567.25 → 2729.97 (+6.3%) | 52.16 → 66.82 (+28.1%) | 83.74 → 83.18 (-0.7%) | 53.88 → 52.49 (-2.6%) |
| HFS / large-file | 3484.86 → 3483.64 (-0.0%) | 50.42 → 51.41 (+2.0%) | 254.74 → 246.63 (-3.2%) | 53.14 → 54.68 (+2.9%) |
| HFS / many-small-files | 2934.05 → 2631.35 (-10.3%) | 50.71 → 39.58 (-21.9%) | 285.91 → 253.90 (-11.2%) | 58.58 → 53.48 (-8.7%) |

Raw phase diagnostics and all repetitions: [APFS JSON](steam-install-baselines/2026-10-12-step-2-apfs.json), [HFS+ JSON](steam-install-baselines/2026-10-12-step-2-hfs.json). Containing and concurrent metric durations overlap; do not sum them to derive elapsed bottlenecks.

## Priorities confirmed

Continue the existing plan order. Step 3 removes repeated chunk validation and SHA-256 journal work: fresh large chunks still accumulate 402,659,328 Adler-32 bytes for 134,219,776 original bytes (three checks), plus journal hashes. Keep real CDN validation within retry and keep retained-chunk validation on resume. The large-file Adler duration sums about 974 ms on APFS and 960 ms on HFS+ with concurrency, so these are operation totals, not serial wall costs.

Checkpoint/sync work remains a major later priority, especially HFS+ large-file: median summed checkpoint time is 2,007.6 ms and file fsync time 1,984.7 ms, within about 3,483.6 ms download elapsed. Small files still perform 514 checkpoints, 1,542 file syncs and 5,656 descriptor-relative walks; APFS small-file checkpoint/walk sums are 497.3/458.1 ms and HFS+ 731.2/259.2 ms. The subsequent three whole-original verification passes remain unchanged, each reading 134,219,776 bytes for the large fixture or 8,390,656 bytes for the small fixture. Transport reuse is directly proven and complete; no findings justify skipping the planned hashing, durability and verification work.
