# PRD 06 — Play session

Journey: **play**. From Play to player control, to clean exit back to Home.

## 1. Launch

- **FR-LAUNCH-1 (v1):** Play runs: installed-state check (files present, drive mounted, bottle
  exists; otherwise offer Verify or Reinstall) → `GameRunner.prepare` (recreate a missing bottle from
  the template and rerun post-install) → `cxstart --bottle gn-<source>-<id> --workdir … --dll …
  <exe> <args>` with the `LaunchSpec` environment.
- **FR-LAUNCH-2 (v1):** A "Launching <title>" state is shown until the game's first window is
  observed; the launcher then lowers its window level and hides its cursor so the game is frontmost.
  No hang detection in v1: the spinner stays and the exit overlay is the escape hatch.
- **FR-LAUNCH-3 (v1):** Launch failure (process exits before a window appears, `cxstart` error)
  returns to the game page with the failing stage and captured output (07 §2).
- **FR-LAUNCH-4 (v1):** Only one game runs at a time; Play on another game asks to quit the current
  one.
- **FR-LAUNCH-5 (v2):** Per-game properties honored: exe, args, env, DXVK vs D3DMetal, resolution,
  language, Steam emu options (DLC list, offline), controller mapping. Editable from the controller.
  Import of GameNative-android configs where fields map (see `GameNative-macos/docs/12`).

## 2. In game

- **FR-INGAME-1 (v1):** The controller is not captured by the launcher; macOS delivers it to the game
  as usual. The launcher only listens for `holdHome`.
- **FR-INGAME-2 (v1):** `holdHome` raises the exit overlay above the game: "Return to game" (default
  focus) and "Quit game". Quit sends a graceful terminate to the game's processes in the bottle, waits
  10 s, then force-kills the bottle's processes (`wineserver -k` scope).
- **FR-INGAME-3 (v1):** The launcher observes the exe PID and the bottle's wineserver; either
  disappearing ends the session.
- **FR-INGAME-4 (v2):** Quick Access overlay on `holdHome`: volume, output device, FPS counter,
  screenshot, quit. Controller battery.
- **FR-INGAME-5 (later):** Frame limiter, performance HUD, streaming to a phone.

## 3. Exit

- **FR-EXIT-1 (v1):** On process exit the launcher restores fullscreen and returns to the game page
  (or Home if the session was started from Home), with focus on Play.
- **FR-EXIT-2 (v1):** Playtime accumulates per session; "last played" updates; the session outcome
  (clean, crash = non-zero status or under 30 s, forced) is recorded (04 FR-COMP-2).
- **FR-EXIT-3 (v1):** A crash shows a toast with "View logs" (07 §3).
- **FR-EXIT-4 (v1):** Paused downloads resume after exit (05 FR-INST-5).
