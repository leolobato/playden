# Observed game focus handoff — 8 September 2026

The launcher could display a keyboard-focus warning after the game had already become active.
It treated the immediate AppKit activation return value as the final result. Live inspection
also exposed an initial Wine window being replaced: once the first window was observed, Sessions
never requested handoff to its replacement.

Handoff now checks the exact process-start identity and CG window owner before requesting
activation. It waits for AppKit registration and observes foreground state for up to two seconds.
An already-active game needs no additional request. A request alone does not establish success,
consistent with the Xcode 26.3 AppKit header and
[Apple's activation contract](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate%28from%3Aoptions%3A%29).

Sessions follows replacement startup windows until the delegate acknowledges a successful
handoff to the currently tracked window. Later window changes do not automatically steal focus.
Opening the exit overlay, ending the session or starting another handoff cancels the pending
activation task. Late completions cannot lower the launcher behind a newly opened overlay or
act on a different session. A workspace activation notification clears a focus warning if the
tracked game becomes active after the bounded attempt finishes.

## Automated validation

All 123 app tests passed, including new coverage for delayed registration, observed activation,
an accepted-but-ineffective request, bounded timeout, cancellation, disappearing/replaced targets,
reused process IDs, and startup window replacement until acknowledgment. The tests also verify
that later window changes do not request another automatic handoff and that the next session
starts with fresh handoff state.

- Tests: `/tmp/bigscreen-game-activation-final-tests.log`.
- Signed build: `/tmp/bigscreen-game-activation-final-build.log`.
- Stable app staging/launch: `/tmp/bigscreen-game-activation-final-run.log`.

## Actual A Short Hike check

Selected Play through the signed app's normal UI. Final session
`7E2E2EBF-EBB9-4F51-ABD6-087CC8B5547D` exercised:

1. Automatic focus after the startup window replacement. The tracked `AShortHike.exe` process
   was the foreground application; the launcher was not manually lowered and the test helper
   did not activate the game.
2. A global Z keypress entered the game menu. The input helper first verified process-start
   identity, the exact window and foreground ownership; it refuses input if the game is inactive.
3. Shift–Home via System Events opened the exit overlay at layer 27 with no focus warning.
4. Return dismissed the overlay. A subsequent global Down keypress selected Options in the
   game's menu, again without a helper activation request.
5. The game's own Quit ended the session cleanly with 128 seconds recorded and restored the
   launcher. No unfinished sessions, Cloud claims, owned Wine processes or unreadable Wine
   processes remained. The overlay was closed and no focus-warning labels were present.

Private evidence: `.build/focus-handoff-live/automatic-menu.png`, `overlay.png`,
`after-return-options.png`, `foreground-before-overlay.txt`, `foreground-after-overlay.txt`,
and `session-final-ended.json`. Earlier inspection/intermediate sessions are retained separately
and are not substituted for this final pass.

This verifies keyboard focus and menu interaction for A Short Hike. It does not establish
physical DS4/TV handoff, controller input leakage, or every other game's window lifecycle.

## Later interrupted run

During launcher-quit testing, session `F2B9E84D-DD4B-4B5D-8B6B-38B602D9A7B8` had Terminal as
the foreground app, an inactive tracked game, and a keyboard-focus warning in the quit dialog.
The cause was not established before the user paused desktop work. The earlier successful
run remains valid evidence for that run, but does not close focus reliability acceptance.
See [the handoff](../NEXT_SESSION_HANDOFF.md) and private evidence under
`.build/launcher-quit-live/`. No further interactive investigation should run until the user resumes.
