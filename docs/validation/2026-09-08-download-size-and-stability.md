# Download size cache and stable progress — 8 September 2026

Game details now load an account-scoped download estimate on demand, without requesting CDN
manifests or chunks. The SQLite cache survives restarts and keeps stale values usable offline.
Known values expire after six hours, unknown metadata after 15 minutes, and library refresh
invalidates freshness. Account changes cannot reuse another account's depot selection.
Installation resolution stores the manifest total and keeps it authoritative for the same
manifest set. Metadata estimates display an approximation symbol.

Read-only inspection of the saved Armored Core VI plan confirms compressed-size metadata is
present for both selected depots (51,758,594,368 and 46,762,992 bytes). Their metadata sum is an
estimate; the previously resolved manifest transfer total is 64,580,321,776 bytes. Opening
details uses metadata cheaply; installation confirmation retains the manifest-derived total.

The download card now uses fixed stat columns and tabular digits. Speed uses an eight-second
window; ETA uses a 30-second window, waits ten seconds before first appearing, and refreshes
at most every five seconds. Time is rounded to minutes, with a final "less than a minute"
label. Stalls clear ETA rather than leaving a stale positive estimate.

Validation:

- BigScreenKit: 255 XCTest tests, 6 existing integration skips, no failures; 5 Swift Testing
  tests passed. New cases cover cache persistence, account separation, metadata refresh,
  invalidation/reset, precise totals, manifest changes, missing sizes, entitled depots and ETA.
- App: 21 focused tests passed, including cache reuse, offline fallback, account changes,
  leaving details during a request, resolved totals, install recovery and reset interactions.
- Reviewed `.build/download-stability-review/install-queue.png`; byte progress, speed and ETA
  occupy separate positions with room for their labels.
- `./scripts/build-release.sh --no-open` passed, including strict code-signature verification.

The current interactive app and download were not restarted for these checks. The earlier
USB download fix is documented separately in [the disk-stall validation](2026-09-08-download-disk-stall.md).
