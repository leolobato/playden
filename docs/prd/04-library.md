# PRD 04 — Home, Library and game page

Journey: **find a game**. The library is a merge of every source's owned games with the user's
local edits. Nothing here names Steam except the artwork endpoint.

## 1. Home

- **FR-HOME-1 (v1):** Home is the landing screen after first run and after a game exits. Rows, top
  to bottom, each hidden when empty: Continue Playing (by last played), Downloading Now, Recently
  Installed, Favorites, then one row per pinned collection.
- **FR-HOME-2 (v1):** The first row's first item is focused on arrival; `home` action returns focus
  there.
- **FR-HOME-3 (v2):** "Play next" row driven by playtime patterns; "New in your library" row from
  source diffs.

## 2. Library

- **FR-LIB-1 (v1):** Left rail: Installed, All, Favorites, Hidden, then user collections. Right: a
  cover grid, 6 columns at 1080p. The rail's selection persists.
- **FR-LIB-2 (v1):** Sort (Options): name, recently played, playtime, recently added. Filters
  (Options): installed state, source (when >1), genre, controller support, compatibility rating.
- **FR-LIB-3 (v1):** Search (touchpad or `search`): live filter across titles; results replace the
  grid; `back` clears.
- **FR-LIB-4 (v1):** Cover states are visible on the tile: not installed (dimmed), queued,
  downloading (progress bar), installed, running, broken (badge).
- **FR-LIB-5 (v1):** Library syncs from each source on launch and every 6 hours; a manual refresh is
  in Settings. Offline shows the cached library.
- **FR-LIB-6 (v1):** A library of 600+ titles scrolls at 60 fps with artwork loading lazily.

## 3. Collections and hiding

- **FR-COL-1 (v1):** Manual collections: create (named via on-screen keyboard), rename, delete, add
  and remove games from the context menu, pin to Home. A game can be in many collections.
- **FR-COL-2 (v1):** Favorites and Hidden are built-in collections. Hidden games leave All and Home
  and appear only under Hidden.
- **FR-COL-3 (v2):** Dynamic collections: a saved filter set (e.g. "installed, controller-friendly,
  under 5 GB") that updates itself. Editable like a manual collection's name.
- **FR-COL-4 (later):** Import Steam's own collections/categories.

## 4. Game page

- **FR-GAME-1 (v1):** Hero art with logo, title, and one dominant action reflecting state: Install,
  Resume download, Play, or Return to game. It is focused on arrival.
- **FR-GAME-2 (v1):** Metadata strip: playtime, last played, install size or download size, source,
  compatibility badge. Description and genre tags below when the source provides them.
- **FR-GAME-3 (v1):** Secondary actions row: Favorite, Add to collection, Hide, Uninstall (when
  installed), Set compatibility, Properties (v2), View logs (07).
- **FR-GAME-4 (v1):** When a job for this game is active, the page shows its stage and progress inline
  (05 FR-INST-2).
- **FR-GAME-5 (v2):** Achievements owned, DLC owned and enabled, screenshots gallery.

## 5. Compatibility

- **FR-COMP-1 (v1):** Every game has a rating: Untested (default), Works, Playable (with note),
  Broken (with note). The user sets it from the context menu or game page; the note is free text via
  the keyboard. Shown as a badge on tiles and the game page and usable as a filter.
- **FR-COMP-2 (v1):** The launcher records the last session outcome (clean exit, crash, forced quit)
  and shows it on the game page; it never changes the user's rating on its own.
- **FR-COMP-3 (v2):** Seeded ratings and notes from a shared list (your own verified results, later
  the GameNative community data). Seeded values are labeled as such and are overridable.
- **FR-COMP-4 (later):** Export ratings back to the community.

## 6. Artwork and metadata

- **FR-ART-1 (v1):** For Steam titles fetch library capsule (600×900), hero (1920×620), logo and
  header from the Steam CDN by app id; cache on disk; show a generated placeholder (title on a color
  derived from the id) until art arrives or when none exists.
- **FR-ART-2 (v2):** SteamGridDB fallback for missing art and for non-Steam sources; user can pick an
  alternative cover.
- **FR-ART-3 (v1):** Metadata (genres, controller support, description) from the source's
  `metadata(for:)`; cached; refreshed with the library sync.
