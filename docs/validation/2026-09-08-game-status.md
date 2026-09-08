# Game status and exit destination — 8 September 2026

The v1 UI audit identified concrete differences between the PRD/implementation plan and the app:

**Tile-design correction:** the later fidelity audit removed Works/Playable tile badges to match
the designer's explicit rule that Broken is the only compatibility badge on covers. Those ratings
remain on game details and in filters. Running still has its status badge. See
[tile fidelity validation](2026-09-08-tile-fidelity.md); the table below records the original checkpoint.

| Requirement | Finding | Change |
| --- | --- | --- |
| FR-EXIT-1 / plan return destination | A Library-launched game returned to details. | Normal, crashed and forced exits return to Home, focusing the played game when present or the first available Home item. Launch failures retain their origin's game page. Post-exit Cloud conflict recovery still opens its review panel. |
| FR-COMP-2 | Session outcomes were persisted/mapped into `Game`, but never displayed. | Game details show the last session outcome with an icon and explicit text, separately from the user's compatibility rating. |
| FR-LIB-4 / FR-COMP-1 | Running and user-set Works/Playable states had no tile badge. | Running, Works and Playable badges join the existing queued/disconnected/Broken badges. Running suppresses a stale download mark. |
| FR-OVL-1 | Context menu began with Open game and omitted Uninstall. | The primary action reflects the game's actual state and uses the existing detail action; eligible installations expose the existing uninstall confirmation and Cloud safeguards. |

The details description/tags/note area now fits above the footer: summary length accounts for
compatibility notes, the last-session label shares the genre row, and an active job uses that area
for its stage, progress and failure instead. Explicitly absent controller support is shown as
“No support”, distinct from unknown metadata.

Validation:
- All 102 app tests passed, including new checks for Library-to-Home exit, played-game focus,
  hidden-game fallback, launch-failure details, unchanged user ratings after a crash, running and
  compatibility badges, and context install/uninstall confirmations. Existing Cloud and uninstall
  interaction tests also pass. `/tmp/bigscreen-game-status-all-app-tests.log`.
- Snapshot fixtures use A Short Hike for clean/crashed session labels, a long compatibility note,
  a running library tile and the uninstall context action. They never launch or modify a live game.
- Signed build passed. `/tmp/bigscreen-game-status-build.log`.
- Five screens rendered at both 1920×1080 and 3840×2160 (4K with reduced motion). Visually inspected
  clean/crashed status text, long notes, running/compatibility badges, the focused Uninstall menu
  entry and the inline download card. Labels and controls fit above the footer. Artifacts are in
  `.build/game-status-1080/` and `.build/game-status-4k/`. The offscreen renderer still omits the
  native game action strip; live action-strip/controller acceptance remains open.
- With zero unfinished sessions and zero Cloud claims, staged/launched the signed app from its
  stable Application Support bundle using normal quit handling. `/tmp/bigscreen-game-status-run.log`.

Full v1 acceptance remains open. Live gameplay, physical DS4/TV flows, cold/warm rendered frame
pacing and the exact Oniken crash trigger still require direct evidence; these UI fixes do not
establish those gates.
