# Temporary primary display prototype

Branch: `feature/temporary-primary-display`, based on `main`. This uses public macOS
Core Graphics APIs and the installed CrossOver without rebuilding or patching Wine.
It has no dependency on the internal ABI of CrossOver 26.2. Other runtime versions
still need testing.

## Setting

Game settings → More settings → **Make game monitor primary → While playing**.
Uses the monitor selected in Playden's Display settings, or the launcher's monitor
when no preference is saved. It is off by default and independent of Virtual desktop.
Compatibility profiles cannot enable it; a per-game user override is required.
Virtual desktop's description points to this option when a game opens on the wrong monitor.

This affects the whole Mac. The Dock, menu bar and other windows may move. Display
configuration is restored after the game ends or Playden exits; macOS may not restore
individual windows to their previous positions. Mirroring is rejected. A disconnected
saved monitor produces an actionable launch error rather than promoting a fallback.

## Lifetime and ordering

1. Validate the game, display identity and bottle ownership. Apply existing bottle
   settings, stop its idle Wine server and wait for it to exit.
2. Start `PlaydenPrimaryDisplay --apply DISPLAY_UUID` with a private stdin pipe.
   The helper translates every display's origin by the same offset, placing the
   chosen display at (0,0), preserving their relative arrangement and display modes.
3. Commit using `CGCompleteDisplayConfiguration(..., .forAppOnly)`. This is a
   system-wide configuration held for the **helper process's** lifetime, not a
   session or permanent configuration write. It is not isolated to Playden's windows.
4. Wait for a JSON acknowledgement confirming the UUID, main-display flag and zero
   origin, then pass freshly captured geometry to the Windows display helper and
   start the game. Failure or cancellation stops the native helper before returning.
5. Keep the pipe open until the tracked game ends, even if the launcher exits first.
   Close it and wait for helper exit before publishing game completion. The helper
   also watches its parent's process lifetime. macOS restores the session/permanent
   display configuration when the helper exits, including after a crash.

The accompanying `RuntimeProcessInspector` fix includes native `wineloader` and
`wine64` paths in the candidate scan. Bottle ownership still requires the matching
WINEPREFIX and process birth identity; argv[0] still distinguishes games from Wine
services. This avoids declaring a live game finished and restoring its display early.

The native helper is compiled and signed by `scripts/embed-primary-display-helper.sh`.
Its layout planning source is shared with Runner so tests exercise the same translation.
Read-only inspection is available without changing a display:

```sh
Playden.app/Contents/Resources/PlaydenPrimaryDisplay --plan DISPLAY_UUID
```

Do not invoke `--apply` from an interactive shell: it requires a supervising pipe.
Normal app launches own that pipe and the cleanup.

## Validation — 2026-09-09

Hardware: LG main (0,0,3008,1692), ASUS VC239 (-1920,0,1920,1080), built-in
(3008,458,1512,982), all dimensions in Mac points. Runtime: installed CrossOver 26.2.
Live checks used a disposable bottle and disabled `winecoreaudio.drv` for every
fixture/game launch. Installed CrossOver and the original bottle were unchanged.

- A five-second native switch made ASUS primary and moved the other origins to
  LG (1920,0) and built-in (4928,458). Closing the pipe restored the original IDs,
  UUIDs, origins, dimensions and primary flags exactly.
- The real CrossOverRunner launched Blades of Time with Virtual desktop 1920×1080,
  tracked its real process/window as running, and restored the original layout after
  the bounded 40-second run. No launch-before-window failure occurred.
- With Retina off and the original D3DMetal backend, Blades occupied ASUS at
  (0,0,1920,1080) and rendered its intro. With Retina on, a DXVK placement check
  occupied (0,30,960,540) on ASUS: monitor selection worked but scaling remained.
- With Virtual desktop off, Retina on and D3DMetal, the first sampled loading
  window was already on ASUS at approximately 2.47 seconds. It expanded to
  (0,0,1920,1080) and stayed there through the 40-second observation. All three
  game runs restored the original layout after stopping.
- A visible Windows fixture passed window/child/owned-window placement, move/resize,
  six cursor set/get round trips, and a logical cursor clip rectangle. Native clicks
  produced client (220,140); scrolling produced screen (320,240). These passed with
  Retina both off and on. The initial fixture ran behind Terminal, so its missed
  click was inconclusive; the repeat made the fixture topmost before input injection.
- Killing the native helper after the Retina-on fixture also restored the original
  display layout, exercising crash rollback.
- A separate eight-second window fixture exited naturally through the real runner
  with Virtual desktop enabled. Playden observed its window and exit, and released
  the native helper without a force-stop command. Idle Wine services did not keep
  the temporary main display active.
- Automated tests cover layout planning, disconnected/mirrored/ambiguous layouts,
  explicit opt-in and profile precedence, helper readiness/cancellation/EOF,
  rebased launch geometry, failed-launch cleanup, and game lifetime beyond wrapper exit.

The Debug app build and strict code-signature verification passed. All 49 selected app
settings/display/session tests passed; the full PlaydenKit suite passed as well.

Local evidence and screenshots: `/private/tmp/playden-primary-prototype/`.
These are startup and fixture checks, not a full gameplay or multi-game compatibility pass.

## Remaining limits

- macOS can reject display reconfiguration while another application is fullscreen.
  The prototype reports a launch error; leave fullscreen and retry. It does not yet
  automatically take the launcher out of its fullscreen Space and restore that Space.
- Retina scaling is independent: a 1920×1080 Wine virtual desktop with Retina enabled
  can occupy only 960×540 Mac points. For the tested ASUS fullscreen setup, use High
  resolution off. This option does not silently alter either setting.
- Raw mouse look, extended gameplay, additional games/runtime versions, fullscreen
  Spaces, unplugging a display during play, and concurrent changes in System Settings
  need further testing. Existing app-scoped configurations from other display tools
  are not promised to survive; Core Graphics restores the session/permanent configuration.

API contract: the installed SDK's `CGDisplayConfiguration.h`, especially
`CGConfigureDisplayOrigin` and `CGCompleteDisplayConfiguration` / `kCGConfigureForAppOnly`.
