# PRD 07 — Settings, failures, diagnostics and testing

Journey: **fix something**. Where the user goes when a step failed, and the engineering contract
that makes that possible.

## 1. Settings

- **FR-SET-1 (v1):** Account: connected sources with identity, sign in, sign out. Library: refresh
  now, games volume, download-while-playing toggle. Display: which display, reduced motion.
  Controller: connected pads, a button test screen. About: version, CrossOver version detected,
  template version, open logs folder (for a keyboard-and-mouse moment), reset app data.
- **FR-SET-2 (v2):** Default per-game properties; artwork source and API key; helper status.
- **FR-SET-3 (later):** Kiosk options, power, multiple profiles.

## 2. Failure contract

- **FR-FAIL-1 (v1):** Every job and launch failure produces a `Failure` with: stage, a one-sentence
  human reason when the cause is recognized, the raw tool output, and a timestamp. It is shown where
  the user is (game page, Downloads, toast) and stored.
- **FR-FAIL-2 (v1):** Recognized causes at minimum: no network, sign-in expired, insufficient space,
  drive disconnected, CrossOver missing, bottle creation failed, exe not found, process exited
  immediately. Unknown causes say "failed at <stage>" and offer logs.
- **FR-FAIL-3 (v1):** Retry is offered wherever the failure is shown and re-enters at the failing
  stage, not from the start.

## 3. Logs

- **FR-LOG-1 (v1):** Per install job and per play session, a log file under
  `Application Support/GameNative BigScreen/logs/<source>-<id>/`, capturing tool stdout/stderr and the
  launcher's stage timeline. Rotated to the last 10 per game.
- **FR-LOG-2 (v1):** "View logs" shows the latest log in a scrollable overlay on the TV; "Reveal in
  Finder" exists for desk debugging.
- **FR-LOG-3 (v2):** Export a debug bundle (logs, config, bottle conf, system info) to a file.

## 4. Testing strategy

- **TS-1 (v1):** `Focus`: unit tests with geometry fixtures for every rule in 03 §2 (nearest,
  column-keeping, edge hand-off, memory, modal trap).
- **TS-2 (v1):** `Input`: synthetic button and stick streams verify mapping, deadzone and repeat
  timing.
- **TS-3 (v1):** `Installs`: a `FakeInstaller` that fails at each stage; tests for persistence and
  resume after a simulated restart, pause/cancel cleanup, queue ordering.
- **TS-4 (v1):** `Runner`: integration test that creates a throwaway bottle from the template,
  launches a trivial Windows exe, observes exit and deletes the bottle. Skipped when CrossOver is
  absent.
- **TS-5 (v1):** `Sources`: `SteamSource` against recorded fixtures (`SteamCore` already ships
  fixtures); `FakeSource` proves FR-SRC-4.
- **TS-6 (v1):** UI: snapshot tests of each screen at 1080p and 4K, with focus on the first item;
  reduced motion on.
- **TS-7 (v1):** Manual acceptance: the MVP bar in README, run with a DualShock 4 on the TV.
