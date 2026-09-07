# GameNative Big Screen — designer prompt

Design the TV interface for **GameNative Big Screen**, a macOS launcher that lives on a television
and is driven entirely by a game controller. It shows the user's game libraries, installs Windows
games and plays them. Think Steam Deck's gaming mode, PlayStation's home, or Apple TV, not a desktop
app: no mouse, no keyboard, no windows.

The core experience is: **pick up the controller → find a game → Play.** Installing is the secondary
loop: **find a game → Install → wait → Play.** Make both feel immediate and trustworthy.

## Product context

The primary user sits 3 m from the TV with a PlayStation DualShock 4. Their Steam library has about
600 games; a handful are installed at any time. Games run through a compatibility layer
(CrossOver) in their own "bottle", but the UI never says Wine, bottle or CrossOver in ordinary
flows: it says Install, Preparing, Play. Component names belong in Settings and logs.

The app supports several stores over time (Steam first, then GOG, itch.io, Epic). Design so a source
label or icon can appear on tiles and the game page without redesign, but do not make the store the
organizing principle; the user's library is.

Do not imply that every game works. Compatibility is a user-set rating with four values: Untested,
Works, Playable, Broken.

## Visual direction

Artwork-led, dark by default (a TV in a living room), with a single light variant for bright rooms.
Large type, generous spacing, a bold and unmistakable focus state (scale plus ring plus title
emphasis, not color alone). Restrained accent color; the game art supplies the personality. Avoid
dense dashboards, small text, hover-only affordances and anything that assumes a pointer.

Design at **1920 × 1080** and show how the layout holds at **3840 × 2160** (same proportions, crisper
art). Keep a 5% safe-area inset on all sides. Respect reduced motion. Communicate state with text
and icons as well as color.

## Controller vocabulary

Every screen has a bottom legend showing the available actions with the controller's glyphs.
Default mapping: D-pad and left stick move focus; Cross confirms; Circle goes back; Triangle opens
the context menu for the focused game; Square toggles favorite; Options opens sort and filters;
L1/R1 switch top tabs; L2/R2 page through grids; touchpad click opens search; PS short press returns
to Home; PS held for one second while a game runs opens the exit overlay.

Design the focus ring, the legend, and how a tile looks in each install state: not installed
(dimmed), queued, downloading (progress), installed, running, broken.

## Required screens

### 1. First run
- Controller pairing instructions with a "press Cross to continue" confirmation.
- Steam sign-in by a large QR code with states: waiting, approved, expired (auto-renews), no
  network. A secondary credentials path using the on-screen keyboard.
- Games volume picker (list of drives with free space) and a "preparing" step with progress.
- Display picker when more than one display is present.

### 2. Home
- Landing screen. Horizontal rows: Continue Playing, Downloading Now, Recently Installed,
  Favorites, pinned collections. Rows hide when empty. First tile focused on arrival.
- Persistent top bar: tabs Home, Library, Downloads, Settings; account avatar; clock.
- Bottom bar: button legend and a compact download indicator.

### 3. Library
- Left rail: Installed, All, Favorites, Hidden, user collections. Right: cover grid, six columns at
  1080p, with tile states above.
- Sort and filter panel opened by Options: sort by name, recently played, playtime, recently added;
  filters for installed state, source, genre, controller support, compatibility.
- Search results view with live filtering; empty result state.
- Loading, empty library (not signed in), offline (cached) and artwork-missing placeholder states.

### 4. Game page
- Hero art with logo, title, one dominant action reflecting state: Install, Resume download, Play,
  Return to game. Focused on arrival.
- Metadata strip: playtime, last played, size, source, compatibility badge. Description and tags.
- Secondary actions row: Favorite, Add to collection, Hide, Uninstall, Set compatibility,
  Properties (v2), View logs.
- Inline job progress when this game is installing.
- Set-compatibility sheet: four ratings plus a note field.

### 5. Downloads
- Queue: active job with stage, percent, bytes, speed, ETA; queued jobs; recent completed and
  failed. Context menu: pause, resume, cancel, retry, move up/down.
- Storage bar for the games volume: used, reserved by queue, free.
- Failed state showing stage and a one-sentence reason with Retry and View logs.

### 6. In-game overlays
- Launching state ("Launching TUNIC…") shown before the game takes over.
- Exit overlay over a dimmed game frame: Return to game (default), Quit game.
- (v2) Quick Access panel: volume, output device, FPS toggle, screenshot, quit, controller battery.

### 7. Settings
- Account (sources, sign in/out), Library (refresh, games volume, download while playing), Display
  (which display, reduced motion), Controller (connected pads, button test), About (versions, logs,
  reset).

### 8. Shared components
- Context menu for a game.
- Confirm dialog (title, one-sentence consequence, two buttons).
- Toasts: download complete, install failed, controller connected/disconnected.
- On-screen keyboard: QWERTY with shift and symbols, with shortcut chips showing Square = backspace,
  Triangle = space, L1/R1 = cursor, Options = symbols. Masked mode for passwords.
- Log viewer overlay: scrollable monospaced text on the TV.

## Deliverables

- Dark and light themes for Home, Library, Game page and Downloads; dark only is acceptable for the
  rest.
- One artboard per screen above at 1920 × 1080, plus Home and Library at 3840 × 2160.
- A components sheet: tile states, focus ring, legend, context menu, dialog, toast, keyboard, badges.
- Short notes on motion: focus transitions, row scrolling, hero crossfade, all with a reduced-motion
  alternative.

Use real Steam-style artwork proportions: cover 600 × 900, hero 1920 × 620, logo on transparent.
Placeholder titles are fine; do not invent compatibility ratings, FPS numbers or store branding.
