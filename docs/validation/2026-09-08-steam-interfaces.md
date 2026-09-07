# SteamCore interface repair integration — 8 September 2026

User-supplied fix `c5dfc3f289acb5097e31d2fea4045e19095a2ca2` was cherry-picked with provenance into
GameNative-macos main as `9ce9f16`, and into the active sibling checkout's `investigation/ios-runtime`
branch as `13312ff`. The latter is the local package used by Big Screen. Existing uncommitted
documentation/iOS work was preserved. Main was updated in a temporary isolated checkout, which
was removed after its tests; the supplied fix worktree was not modified. No SteamCore commit was
cherry-picked into big-screen.

Validation:
- Active sibling SteamCore suite: 64 tests, 2 skipped, no failures.
  `/tmp/bigscreen-steamcore-sibling-tests.log`.
- Main's smaller baseline suite: 17 tests, 1 skipped, no failures.
  `/tmp/bigscreen-steamcore-main-tests.log`.
- Signed Big Screen rebuilt successfully with the updated local package and was staged/launched
  from its stable Application Support bundle. `/tmp/bigscreen-steam-interfaces-build.log`.
- Big Screen regression suite with the updated dependency: 135 package XCTest tests (3 existing
  integration skips), 5 Swift Testing tests and 55 app tests passed.
  `/tmp/bigscreen-steam-interfaces-all-tests.log`.

## Live installation repair

With no unfinished session or Oniken process, recorded hashes for all 37 game files and backed up
original DLLs, settings, interfaces and save/config data into the private ignored directory
`.build/oniken-interface-validation/before/`.

Used the rebuilt Big Screen Library → Oniken → Verify files action. The normal repair queue ran
`SteamInstaller.postInstall` against the pinned manifest and completed job
`760F899D-0A81-4456-AAE6-047B8FB38418` successfully. No direct hand-edit of interface configuration
was used. In `~/Games/GameNative/gn-steam-252010/game`, all four files contain 17 interfaces and
include `STEAMUSERSTATS_INTERFACE_VERSION011`:

- `steam_interfaces.txt`
- `steam_settings/steam_interfaces.txt`
- `DATA/steam_interfaces.txt`
- `DATA/steam_settings/steam_interfaces.txt`

Only the two existing interface files changed, and the two canonical files were added. Every other
existing file, including both original DLLs, `configs.*.ini`, `DATA/save.dat` and `DATA/config.dat`,
retained its SHA-256. No files were removed. Evidence inventories: `before.json`,
`after-preparation.json` and `after-live-test.json` under `.build/oniken-interface-validation/`.

## Live behavior and remaining reproduction

Launched Oniken through Big Screen, clicked Play in its Windows launcher, skipped the intro,
reached the mission menu and selected Quit Game. The tracked session
`D41ABDC5-0877-499F-A354-5E66C09AB97F` ended cleanly without an observed error dialog.

A second launch inspected Submit Score: it opens Submit Leaderboards confirmation, followed by
a name-entry dialog. Cancelled before submitting an entry. Closed this launcher through Big
Screen's Quit game flow; that wrapper required the existing timeout/forced fallback (session
`751EF28C-91CA-4C4D-A5D8-0D572059C93B` recorded forced). Both sessions are ended, and all originals,
app settings and save/config data still match the pre-test hashes.

Owned-window captures are in `.build/oniken-interface-validation/`: `launcher.png`, `game-menu.png`,
`quit-selected.png`, `submit-after.png`, `submit-result.png`, `submit-cancelled.png`. The helper
captures only windows belonging to the tracked Oniken processes. Launcher mouse interaction
needed foreground, correctly positioned global mouse events; initial PID-only clicks did not
activate its Play button.

**The precise UI action that previously triggered Store User Data is not yet confirmed.** Asked
the user which action it was. Launch/menu/quit is live evidence, but is not proof that the exact
reported crash action has been replayed. Keep that acceptance item open until the trigger is
identified and exercised. No Cloud sync behavior is claimed by this interface repair.
