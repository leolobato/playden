# Minimal-environment app execution — 8 September 2026

Validated the signed staged Big Screen app at `e2d6867`, using sibling GameNative-macos
`608a619ee02e0a56ca223dd732d807b013330658`, on macOS 26.6.2 with CrossOver 26.2.
Both the diagnostic read and the normal app were started with `env -i`, retaining only
`HOME`, `PATH=/usr/bin:/bin` and `LANG=en_US.UTF-8`. The normal app used `--windowed`.

Results:

- `otool -L` on the executable, app debug dylib and bundled `liblzma.5.dylib` /
  `libzstd.1.dylib` found no `/opt/homebrew` or `/usr/local` references.
- The app's `--cloud-read-check 1055540` diagnostic authenticated using the existing account
  and downloaded the one present A Short Hike Cloud file. It verified all 29,453 bytes against
  the remote checksum; remote revision 4 was unchanged. The save SHA-256 was
  `2f605ed8620e2c8b0d4d3fdf9d40f38abe2a4b3594f0a75a2ac0d754382be591`.
- The normal app rendered the signed-in Home screen with bundled typography and library art.
  Its captured native window was visually inspected.
- A Short Hike launched through the normal Play action. Session
  `BB7273E6-6D64-453D-A449-8BF98D3DB7B1` reached running with a tracked game window.
  The game became the active foreground app without the test helper activating it. The helper
  checked PID/start identity and window ownership before sending keyboard input.
- Keyboard input opened the title menu and selected its Quit action. No saved world was loaded
  in this check. The game exited through its own menu; the recorded outcome was `clean`.
- After shutdown there were zero unfinished sessions, zero job claims and zero processes owned
  by this game's Wine runtime. The recorded Cloud operations were completed. Big Screen then
  quit normally with exit status 0 and was reopened through Launch Services for normal use.

Private evidence is in `.build/minimal-environment/`: `linked-libraries.txt`,
`cloud-read-report.json`, `ashorthike-live.png`, `game-foreground.txt`, `game-menu.png`,
`quit-selected.png`, `session-running.json`, `session-final.json` and
`cloud-operations-final.json`. Process output is in `/tmp/bigscreen-minimal-environment-app.log`
and `/tmp/bigscreen-minimal-environment-cloud.log`.

This satisfies the development-shell independence check on the configured machine. It does
not establish first-time setup on a clean Mac, physical DS4/TV acceptance, another game's
compatibility, or the remaining full v1 acceptance matrix.
