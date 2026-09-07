# Game display placement — 7 September 2026

The preferred display now applies to launched games as well as Big Screen. A bundled Windows
helper starts the original executable inside its existing owned bottle and moves that child's
window during its first ten seconds. It preserves the working directory, DLL overrides, Unicode
arguments and child exit status. It does not change the Mac's primary display.

## Verified

- A Short Hike launched from the real Steam library through the signed app on both displays.
- With Built-in Retina Display selected, the actual game window was at Core Graphics
  `(3008, 458, 1512, 982)`, while LG Ultra HD remained the Mac's main display.
- The rendered title and game menu were inspected. A held keyboard Z press reached the menu;
  instantaneous synthetic key presses were unreliable. Physical DS4 gameplay is still unverified.
- The launcher overlay's Quit game stopped the first run via its force fallback. On the LG
  run, selecting Quit inside the game menu produced exit code 0, no forced stop and no failure.
  Save/reload remains unverified.
- The Windows argument fixture preserved Unicode, empty arguments, quotes, trailing backslashes
  and shell-like literals; exit status 37 survived the helper and cxstart. Missing display
  geometry used the primary-display fallback.
- `./scripts/test.sh`: 82 package XCTest cases (79 passed, 3 existing skips), 5 Swift Testing cases,
  and 48 app tests passed. Total: 132 passed, 3 skipped. `git diff --check` passed.

Screenshots: `.build/display-ui/ashorthike-preferred-monitor.png`,
`ashorthike-preferred-input.png`, and `ashorthike-lg.png`. Test log:
`/tmp/bigscreen-game-display-verified-tests.log`.

## Launch fixes found during validation

Running a bundled Windows helper from the repository inside Documents triggered a hidden macOS
Documents permission dialog. `scripts/run.sh` now stages the signed launch copy under
`~/Library/Application Support/Big Screen/Run`. The Documents request was declined and the game
then launched successfully from the new location. The app was already unsandboxed; this avoids
an unnecessary protected-folder access rather than bypassing macOS permissions.

Wine bootstrap loaders must not count as a game that has started and exited. Before the first
window, the live launcher owns startup. An already attributed process remains tracked when its
birth identity still matches, even if a prefix scan temporarily omits it. Regression tests cover
these transitions and PID reuse. Child processes now inherit only explicitly configured standard
streams, without unrelated GUI file descriptors.

## Remaining coverage

Monitor placement currently follows the direct child, so executables that hand off to another
process need further coverage. Games can override their placement after startup. Physical
controller gameplay, save/reload and unplug/reconnect during gameplay remain separate
v1 acceptance checks.
