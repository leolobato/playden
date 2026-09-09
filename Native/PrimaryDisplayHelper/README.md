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

1. Validate the game, display identity and bottle ownership. Resolve High resolution
   against the selected monitor’s AppKit backing scale: a 1× monitor uses RetinaMode=n,
   preserving the saved preference for future 2× displays. Apply the effective bottle
   settings, stop its idle Wine server and wait for it to exit.
2. Capture Playden’s physical monitor UUID and its normal window frame relative to
   that monitor. Leave its fullscreen Space before changing display configuration.
   Start `PlaydenPrimaryDisplay --apply DISPLAY_UUID` with a private stdin pipe.
   The helper translates every display's origin by the same offset, placing the
   chosen display at (0,0), preserving their relative arrangement and display modes.
3. Commit using `CGCompleteDisplayConfiguration(..., .forAppOnly)`. This is a
   system-wide configuration held for the **helper process's** lifetime, not a
   session or permanent configuration write. It is not isolated to Playden's windows.
4. Wait for a JSON acknowledgement confirming the UUID, main-display flag and zero
   origin, then pass freshly captured geometry to the Windows display helper and
   reposition Playden using the monitor’s new AppKit frame. Keep it windowed during
   play so Wine opens on the desktop without a competing launcher fullscreen Space.
   Failure or cancellation rolls back both the native
   helper and launcher presentation before returning.
5. Keep the pipe open until the tracked game ends, even if the launcher exits first.
   Leave Playden’s fullscreen Space, close the pipe and wait for helper exit, then
   restore Playden’s monitor-relative window position. Bring it onto the active Space
   before restoring its original fullscreen state, then publish game completion. Normal preferred-monitor centering is suppressed
   for that return to the launcher. The helper
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
  Playden now leaves and restores its own fullscreen Space around both transactions;
  it does not change other applications’ fullscreen state.
- Retina virtual-desktop dimensions remain Wine pixels. On a 2× display, 1920×1080
  therefore occupies 960×540 Mac points. On ASUS (1×), it occupies 1920×1080 even
  when the saved High resolution preference is On.
- Raw mouse look, extended gameplay, additional games/runtime versions, fullscreen
  Spaces, unplugging a display during play, and concurrent changes in System Settings
  need further testing. Existing app-scoped configurations from other display tools
  are not promised to survive; Core Graphics restores the session/permanent configuration.

API contract: the installed SDK's `CGDisplayConfiguration.h`, especially
`CGConfigureDisplayOrigin` and `CGCompleteDisplayConfiguration` / `kCGConfigureForAppOnly`.

## Window and sizing regression fix

The original prototype did not preserve Playden’s fullscreen Space and applied
Wine RetinaMode=y indiscriminately on ASUS. The app now wraps the native lease with
`LauncherDisplayPresentation`, including failed/cancelled-launch rollback, and resolves
Retina against `GameDisplayTarget.backingScaleFactor` without rewriting user preferences.

Real AppKit tests on the connected ASUS exercised a fullscreen Playden window,
actual CrossOverRunner, the native helper, an eight-second naturally exiting Windows
fixture, and a muted 30-second Blades run. Both retained Playden’s ASUS UUID/fullscreen
state, restored the original monitor configuration, and recovered its exact normal
window frame after leaving fullscreen. Those checks did not assert game visibility
or the absence of a window-mode popup; the desktop handoff follow-up below adds both. The Blades run kept High resolution requested
On, wrote effective RetinaMode=n, and produced a 1920×1080 game window on ASUS.
The initial live test used an outdated hardcoded monitor UUID and stopped before the
game launch; the test was corrected to discover the connected ASUS UUID dynamically.

Regression coverage includes monitor-relative AppKit coordinate translation, windowed
and fullscreen switch/restore, native failure, failed fullscreen reentry, cancellation
while leaving fullscreen and after acquiring the helper, and target-dependent Retina
settings reaching the registry without changing the requested virtual-desktop size.
Evidence: `fixed-lifetime-fullscreen.json`, `fixed-blades-fullscreen.json`, and the
saved opt-in `LiveDisplayFixTests.swift` in the local evidence directory above.

The follow-up regression run passed 314 PlaydenKit XCTest cases (six opt-in cases
skipped), five Swift Testing cases, and 54 selected app tests. The live fixture and
Blades tests were explicitly enabled for this session and are not part of normal CI.

## Desktop handoff follow-up

The first window-preservation fix reentered Playden’s fullscreen Space before Wine
opened. Blades could remain on another desktop until its Dock icon was clicked, and
an automatic fullscreen transition could leave the generic window-mode warning.
Playden now stays windowed on its original physical monitor during the temporary
primary-display lease and restores its original fullscreen state when the game ends.
Restoration waits for foreground activation and the launcher’s active Space before
asking AppKit to enter fullscreen. Automatic transition failures are checked and
reported by the presentation coordinator after cleanup; manual failures retain the
normal window-mode warning.

Game handoff now requires both an active app and an onscreen tracked window. It
retries activation at most twice per second for five seconds while the target’s PID,
birth identity, and window ID remain valid. This prevents an active app with a hidden
window on another Space from being treated as a successful handoff.

The follow-up passed 35 focused app tests and two opt-in live AppKit runs: muted
Blades of Time and the naturally exiting window fixture. Both asserted automatic
visible activation, no generic warning panel or presentation error, fullscreen
restoration on ASUS, the exact original display layout, and the original normal
window frame. Blades was observed onscreen at (0,0,1920,1080) without a Dock click.
Evidence: `handoff-blades-fullscreen.json`, `handoff-lifetime-fullscreen.json`, and
`LiveDisplayFixTests.swift` in the local evidence directory. Slay the Spire II was
reported working by the user; it was not rerun in this follow-up.
