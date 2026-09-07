# Display and fullscreen settings — 7 September 2026

Settings → Display now has Preferred display, Fullscreen, Start in fullscreen, and Reduced
motion. The current window mode follows AppKit's fullscreen delegate notifications; changing
it does not change the startup preference. Existing profiles retain the fullscreen startup
default. Explicit `--fullscreen` and `--windowed` launches override the saved preference for
that launch only. The View menu's Control–Command–F shortcut remains available.

Display selections save the numeric ID, display UUID, and name. UUID matching takes precedence
over numeric IDs so a different screen cannot inherit a disconnected screen's preference.
Missing preferred screens retain their saved identity and show the current fallback in Settings.
Connected preferred displays are restored after a game exits and after screen changes when no
game is active. The macOS main display arrangement is not modified.

Validation:

- `./scripts/test.sh`: 75 package XCTest cases (72 passed, 3 optional integration cases skipped),
  5 Swift Testing cases passed, and 48 app tests passed. Log: `/tmp/bigscreen-display-tests.log`.
  Four new app tests cover old-profile decoding, startup persistence and temporary overrides,
  native fullscreen acknowledgement, all display rows reachable by keyboard, and disconnected /
  reconnected monitor identity with a recycled numeric ID.
- Final native transition fix built and signed successfully:
  `/tmp/bigscreen-display-transition-build.log`.
- Viewed the `settings-display` snapshot at 1920 × 1080 and 3840 × 2160 under
  `.build/display-ui/`. The new rows use the existing designer typography, toggles, and focus
  styling. The Settings footer now says Select.
- Live startup setting changed through Settings, then normal quit/relaunch with no override:
  Off produced a 1280 × 720 window; On restored fullscreen. The startup preference is left On,
  reduced motion Off, and the original LG Ultra HD monitor selected.
- Live fullscreen monitor selection exercised LG Ultra HD → Built-in Retina Display → LG Ultra
  HD. CGWindow metadata placed the launcher on the appropriate screen: LG at x=0, 3008 × 1692;
  built-in at x=3008, 1512 × 949 below the notch/menu region. The UUID and name were saved by the
  real picker. Startup on the saved built-in display also worked.
- Live testing found that moving and re-entering fullscreen synchronously inside AppKit's exit
  callback can strand the window on the old Space. Follow-up transitions now run on the next
  main-queue turn. Both directions of the monitor switch passed after this fix.
- Control–Command–F exited to the 1280 × 720 window and entered fullscreen again.

Limits and remaining work:

- Monitor disconnect/reconnect resolution is covered by tests; physical unplugging has not
  been exercised while the user is away.
- The preference currently places the launcher. Passing it through to CrossOver game placement
  is still required by the user's request. `cxstart --help` describes `--display` as an X display,
  not a macOS monitor selector. Do not claim that moving the launcher moves a game's window.
- Physical controller operation of these new settings has not been tested; the shared input
  path and keyboard interaction are covered.

Platform references: Apple's
[display UUID conversion API](https://developer.apple.com/documentation/colorsync/cgdisplaycreateuuidfromdisplayid(_:))
and the [Wine Mac driver's configuration implementation](https://github.com/wine-mirror/wine/blob/master/dlls/winemac.drv/macdrv_main.c).
