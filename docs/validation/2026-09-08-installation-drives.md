# Installed-game drive availability — 8 September 2026

FR-STOR-2 previously existed only in preview data: catalog restoration marked all installations
as installed, and selecting the disconnected primary action opened a placeholder. The live
library now resolves each installation's own recorded volume and games-root bookmark through
`GamesVolumeStore`, using its existing UUID validation and no-UI/no-mount bookmark resolution.
The current default download drive does not substitute for any installation's saved location.

The model refreshes when installations change; AppKit notifications refresh on mount, unmount,
volume rename, wake and launcher activation. Shared saved roots are resolved once per refresh.
Cancelled reads and results from a replaced installation cannot update the current state.
Availability is transient presentation state: it does not change catalog installation records,
bookmarks, game files or saves.

Disconnected games retain their Installed filter membership, recent-install Home row, artwork,
metadata and focus. Their primary control is disabled with a reconnect explanation. Checking
an unverified drive also temporarily disables Play. Mouse, keyboard and controller actions use
the same disabled state; no placeholder is opened. Favorite, collection, compatibility and log
actions remain available. On reconnection the action returns to Play, or Verify files when
repair is required. An active/failed maintenance job retains its Downloads action so recovery
is not hidden behind an unavailable drive. The hard-coded “On VM” tile subtitle was removed.

Validation:

- All 132 app tests passed: `/tmp/bigscreen-drive-final-tests.log`.
- An isolated two-volume catalog verifies that only the disconnected drive's games change,
  changing the default install drive has no effect, installed/recent rows remain populated,
  focus and personalization survive, disabled primary/context confirmation does nothing, and
  reconnect restores the correct action without changing the installation record.
- A held read plus replacement installation verifies checking-state interaction and rejection
  of cancelled/stale results. A repair fixture verifies disconnected state wins over repair
  while active queue management remains reachable.
- A real `GamesVolumeStore` test selects a disposable local games root, resolves its saved
  bookmark, then changes the recorded UUID. The game becomes disconnected even though the
  original folder still exists. This is a real filesystem/identity check, not a simulated
  `fileExists` failure. The temporary folder is removed after the test.
- Native captures cover game-page disconnected/checking, disconnected context menu and library
  tile at 1920×1080 and reduced-motion 3840×2160. Evidence is private under
  `.build/drive-availability-1080/` and `.build/drive-availability-4k/`.

This does not claim a physical external-drive unplug/replug test or gameplay after reconnect.
The real VM volume and game installations were not unmounted or modified for this change.
