# Cover badge fidelity — 8 September 2026

The designer's shared tile-state guidance explicitly limits compatibility badges on covers to
Broken. The prior game-status checkpoint added Works/Playable badges beyond that guidance.
Removed those two cover badges; Running, Queued, Drive disconnected, Broken and download state
remain visible. Game details and Library filters retain all four compatibility ratings.

- Updated the existing tile-state regression to match the design. All 108 app tests passed:
  `/tmp/bigscreen-tile-fidelity-tests.log`.
- Signed build passed: `/tmp/bigscreen-tile-fidelity-build.log`.
- Rendered Library Running and A Short Hike clean-session details at 1080p and 4K, with reduced
  motion: `.build/tile-fidelity-1080/`, `.build/tile-fidelity-4k/`.
- Visually inspected the 1080p grid (Running/Broken badges, unbadged Playable cover) and 4K
  details (Works still present). Offscreen rendering continues to omit the native game action
  strip; it is not evidence for that strip's live behavior.
- Staged/launched the signed app with no unfinished sessions or Cloud claims:
  `/tmp/bigscreen-tile-fidelity-run.log`.

This is a cover presentation correction; user ratings are unchanged.
