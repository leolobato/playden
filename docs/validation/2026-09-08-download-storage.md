# Downloads storage — 8 September 2026

Implemented PRD 05 FR-DL-2's production storage breakdown using the Downloads mockup's right-hand
card. It shows measured game-file storage, remaining queue reservations, other used space and free
space after the queue, plus total/available capacity and an explicit shortage when needed.

## Behavior and accounting

- Resolve the selected games folder through its saved volume identity before reading capacity,
  and revalidate after measuring. A failed read clears old figures; reconnect is checked again
  automatically. Changing the selection rejects the previous read's late result.
- Measure allocated file blocks in verified owned installation folders and partial-download
  folders on the selected volume. Deduplicate installation/maintenance ownership and hard-linked
  files. Read directory entries through descriptors without following symbolic links; reject
  unexpected nested filesystems. Unverifiable folders make the game figure unavailable rather
  than falsely reporting zero.
- Use the same remaining reservation calculation in install offers, the queue worker and UI.
  Include unfinished install jobs, including paused/failed jobs; exclude repair/removal and
  completed/cancelled jobs. Subtract completed bytes and saturate overflows. UI reservations
  update immediately from queue events; filesystem measurements refresh every 15 seconds while
  Downloads is displayed and cancel when the screen leaves.
- Reservations are part of currently available space, not already-used space. The bar partitions
  games, other used files, reserved capacity and free-after-queue without counting reservations
  twice. Capacity is clamped to the volume's reported total. An overcommitted queue reports the
  full reservation and explicit shortage while its bar segment is bounded by available capacity.

Allocated-file totals are an estimate on filesystems with shared extents such as APFS clones;
folder metadata is excluded. Runtime/bottle files outside the owned game folders contribute to
other used space, not the game-file total. This card does not change install placement or claim
that every used byte on the drive belongs to games.

## Validation

`/tmp/bigscreen-storage-all-tests.log`: 181 package XCTest tests (4 existing integration skips),
5 Swift Testing tests and 69 app tests passed. New coverage checks reservation states/volumes,
overflow, capacity partitions, real owned files and partial downloads, hard-link deduplication,
external/cyclic symlink exclusion, invalid ownership, disconnected reads, stale selection results
and immediate reservation updates without another filesystem scan.

Rendered and inspected normal, low-space and unavailable storage at 1080p:
`.build/download-storage-ui/`. Inspected the low-space layout at 4K:
`.build/download-storage-ui-4k/install-storage-shortage.png`.

Staged and launched the signed production app using `scripts/run.sh`, with no active game session.
The real Downloads screen showed the VM volume, 420.5 MB of games and zero queue reservations.
Independent read-only file allocation counting confirmed 420,536,320 bytes: Aggelos 82,468,864 and
A Short Hike 338,067,456. Capacity at capture was 499.97 GB total / 176.7 GB available; available
space is expected to change with other activity. Capture: `.build/download-storage-live/current.png`.
No games, saves or drive preferences were modified during this validation.

Physical drive removal/reconnection while installing remains a separate acceptance item. Download
speed/ETA and dismissible retained history remain outstanding FR-INST-2/FR-DL-3 work.
