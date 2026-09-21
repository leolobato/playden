# PRD 06 — Play session

Journey: **play**. From Play to player control, to clean exit back to Home.

## 1. Launch

- **FR-LAUNCH-1 (v1):** Play runs: installed-state check (files present, drive mounted, bottle
  exists; otherwise offer Verify or Reinstall) → `GameRunner.prepare` (recreate a missing bottle from
  the template and rerun post-install) → pre-launch cloud sync/conflict resolution (05 §6) → `cxstart --bottle playden-<source>-<id> --workdir … --dll …
  <exe> <args>` with the `LaunchSpec` environment.
- **FR-LAUNCH-2 (v1):** A "Launching <title>" state is shown until the game's first window is
  observed; the launcher then lowers its window level and hides its cursor so the game is frontmost.
  No hang detection in v1: the spinner stays and the exit overlay is the escape hatch.
  During preparation and window waiting, hold Circle/B (the configured Back button) or Escape
  for one second to open quit controls; a short press does nothing. Save syncing retains its
  Save sync action. PS/Home hold remains the in-game shortcut.
- **FR-LAUNCH-3 (v1):** Launch failure (process exits before a window appears, `cxstart` error)
  returns to the game page with the failing stage and captured output (07 §2).
- **FR-LAUNCH-4 (v1):** Only one game runs at a time; Play on another game asks to quit the current
  one.
- **FR-LAUNCH-5 (v2):** Per-game properties honored: exe, args, env, DXVK vs D3DMetal, resolution,
  language, Steam emu options (DLC list, offline), controller mapping. Editable from the controller.
  Import of other launcher configurations where fields map.

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

- **FR-EXIT-1 (v1):** On process exit the launcher restores its presentation and returns to Home,
  focusing the just-played tile when visible, otherwise the normal Home fallback. Launch failures
  return to the game page. This follows the implementation plan's return-destination correction.
- **FR-EXIT-2 (v1):** Playtime accumulates per session; "last played" updates; the session outcome
  (clean, crash = non-zero status, forced) is recorded (04 FR-COMP-2). A short clean session remains
  clean; duration alone does not imply a crash, as specified by the implementation plan.
- **FR-EXIT-3 (v1):** A crash shows a toast with "View logs" (07 §3).
- **FR-EXIT-4 (v1):** Paused downloads resume after exit (05 FR-INST-5).

- **FR-EXIT-5 (v1):** After a game stops writing, synchronize changed saves through the source and
  persist any pending upload or conflict (05 §6). Returning to the launcher must show sync state
  and must not report Up to date before the remote commit succeeds.
