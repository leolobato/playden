# Wine monitor startup investigation — 8 September 2026

The user's preferred ASUS VC239 display and Big Screen both occupied
`(-1920, 0, 1920, 1080)`. A Short Hike's fullscreen window instead occupied the
LG primary display `(0, 0, 3008, 1692)`. Core Graphics and a read-only Win32 probe
reported matching monitor coordinates, including the negative ASUS origin.
The installed display helper matched the current source build and logged that
the game kept its own display setting; it did not take the missing-monitor fallback.

A single process-scoped Win32 placement using the helper's existing flags moved
the running game successfully. Both Windows and Core Graphics then reported the
ASUS bounds exactly, with fullscreen dimensions preserved. The game remained
running; no game restart, input event, save modification, or system primary-display
change was performed. The user's unfinished focus work remains in the named stash.

The helper stopped observing ten seconds after process creation, including time
spent loading without a visible window. This is a reproducible startup gap; the
old session log does not establish when this game's first window appeared, so the
specific launch's timing remains an inference. The countdown now starts at the
first eligible visible child window. Waiting for that window ends when the child
exits. Movement remains limited to ten seconds after window discovery. New log
messages distinguish waiting for a window from attempting placement.

`python3 scripts/test-display-helper.py --bottle <idle owned bottle>` passed:

- Real Wine child argument transport, exact quoting/Unicode/empty arguments,
  child exit status, and disconnected-display fallback.
- Deterministic Win32 boundary tests of the actual helper: windows appearing at
  12 and 32 seconds, unrelated/hidden/tiny window exclusion, fullscreen placement
  on a negative-origin smaller display, an engine's startup display reset,
  bounded retries when placement is rejected, preserved windowed dimensions,
  and child exit before any eligible window.

Ignored evidence: `.build/wine-monitor-investigation/` contains before/after
Core Graphics geometry, Windows enumeration/placement output, session snapshot,
and regression output. Test execution used idle Oniken's owned bottle and opened
no windows or games. A real cold launch with the updated installed helper is still
required to close live acceptance; the running installed app has not been replaced.
