# Play-session UI validation — 2026-09-07

Play now uses the persistent session service. The launching screen follows `2i-launching`;
the separate transparent exit panel follows `2j-exit-overlay`. The panel has its own input
scope, default Return focus, keyboard/controller legends, a stopping state and retryable quit
errors. Starting another game asks to quit the current one. Session logs and final outcomes
are available from the game page. Normal application quit waits for session/queue shutdown.

The keyboard escape hatch registers Shift–Home only while a game is active. The controller
poller emits hold-Home once per one-second hold, including in the background; ordinary
background navigation is discarded. Physical DS4 handoff/hold remains to be tested.

## Automated and rendered evidence

- `./scripts/test.sh`: 121 passed, three optional runtime checks skipped; log
  `/tmp/bigscreen-session-ui-fullscreen-final-tests.log`.
- Tests cover first-window handoff, launching/overlay focus containment, Home versus game-page
  return, single-game confirmation, hold duration/release, and attribution of exclusive-fullscreen
  game windows while excluding unrelated processes, Wine services and menu strips.
- Rendered fixtures inspected at `.build/session-ui/launching.png`, `exit-overlay.png`,
  `exit-overlay-quit.png`. These use preview metadata, not a running game frame.

## A Short Hike live check

The app downloaded and installed Steam 1055540 (331,636,934 content bytes), verified its pinned
files, prepared its owned bottle and staged the Steam API replacement. Play invoked the real
runner; no temporary launcher or executable recipe override was used.

The first attempt displayed a macOS local-network prompt while the game frame was black. Local
network access was denied for this offline check. Relaunch reached the title screen (captured at
`.build/session-ui/ashorthike-second-game.png`). This is title-screen evidence, not gameplay or
a save/relaunch acceptance pass. The launch configuration's `offline=1` does not disable the
emulator's network interfaces; the upstream distinction is documented in
[GBE connectivity settings](https://github.com/Detanup01/gbe_fork/blob/dev/post_build/steam_settings.EXAMPLE/configs.main.EXAMPLE.ini).
Avoiding the unnecessary prompt during an offline first launch remains follow-up work.

A real Shift–Home sent through System Events opened the exit panel while the game was frontmost.
A bare CGEvent injection did not trigger the registered global hotkey; a separate registration
probe confirmed the System Events path. Local keyboard navigation selected Return and Quit.
The initial quit checks escalated after the grace period, recorded `forced`, restored the game
page with Play focused, and updated Last played. Game control and an in-game clean exit remain
separate acceptance checks.

Live testing found two fullscreen issues: Wine uses window layer 26 (above ordinary floating
panels), and a game can initially open outside the launcher's fullscreen Space. Window inspection
now includes other Spaces, prefers visible/larger game windows, and ignores menu-sized strips.
The exit panel is raised above the observed game window's level. The final fullscreen check is
recorded below when completed.

The final fullscreen launch observed the game window across Spaces and reached the title screen.
Shift–Home created the exit panel at layer 27 above A Short Hike's layer-26 fullscreen window
(`ashorthike-fullscreen-title.png`, `ashorthike-fullscreen-overlay.png`). Return dismissed it;
Quit restored the launcher's fullscreen game page and finalized the session. This does not prove
keyboard gameplay: subsequent tool invocations brought Terminal forward. Activation now yields
to the game before lowering Big Screen's window and reports a declined activation request;
that final adjustment passed the build and still needs an uninterrupted live input check.
