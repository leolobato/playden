# Handoff: Playden — TV interface

## Overview
Controller-only, fullscreen launcher UI for macOS (SwiftUI/AppKit, `PlaydenApp` module per PRD 01). Covers every v1 screen in `GUI_DESIGN_BRIEF.md`: first run, Home, Library, game page, Downloads, in-game overlays, Settings, and shared components. Dark theme only (light variant not designed yet). Designed at 1920 × 1080; all values below are 1080p px and scale ×2 at 4K (FR-DISP-2).

## About the design files
`Playden.dc.html` is a **design reference built in HTML**. It is a static canvas of artboards, not code to ship. Recreate the screens in the SwiftUI/AppKit app using its `Focus`, `Input`, `Catalog`, `Installs` and `Artwork` modules. Open the HTML in a browser to inspect exact values; every style is inline on the element.

Chosen directions (user-approved): **focus ring B** (accent ring + glow) and **game page composition 1e** (hero top, solid panel below). Boards 1a, 1d, 1f, 1g are earlier explorations kept for reference only; 1g's content (installed state) still applies, re-laid-out on 1e.

## Fidelity
**High-fidelity.** Colors, type, spacing, states and copy are final for v1 unless noted "placeholder".

## Design tokens

Colors
- Background `#0E0D0C`; panels/dialogs `#16140F`; log viewer `#0A0908`; canvas chrome only `#1A1816`
- Text primary `#F3EFE9`; secondary `#A8A29E`; body on hero `#D6D0C8`; disabled/tertiary `#6B655F`; text on accent `#1A1210`
- Accent `#F0863A` (buttons, focus ring, progress, badges count)
- Status: works/installed/clean `#7BBF6A`; playable/expired/drive-disconnected `#E2B53C`; broken/failed `#E05A4F`; untested/queued `#6B655F` / `#A8A29E`
- Surfaces: `rgba(243,239,233,.04)` list row, `.06` card, `.08` field/toolbar chip, `.10`–`.14` selected/pressed, `.12`+border `.35` active tab
- Borders: outlined button `2px solid rgba(243,239,233,.2)`; hairline `rgba(243,239,233,.1)`

Type (Google Fonts: Barlow Condensed 500/600/700, Barlow 400/500/600)
- Display/first-run title: Barlow Condensed 600 72/1
- Sheet/dialog title: BC 600 40–56/1.05
- Section label: BC 600 22/1, letter-spacing .12em, uppercase, `#A8A29E`
- Tab: BC 30/1 (600 active, 500 inactive); rail item: BC 28/1; list title: BC 28–36/1
- Primary button: BC 600 38/1; secondary button/chip: BC 500 26/1; dialog buttons BC 28–32
- Body: Barlow 400 26/1.45 (game description), 30/1.35 (first run), 22–24/1 (metadata, list subtitles)
- Legend: Barlow 500 22/1; glyph 600 18/1; tile badge Barlow 600 16/1; focused tile title BC 600 24/1.05 + Barlow 400 15–16 subtitle
- Monospace (logs, placeholders): ui-monospace/Menlo 19/1.55

Spacing and geometry
- Safe area: 96 px horizontal, 54 px vertical. Top bar: y 54, h 56. Content top: y 150. Legend: bottom 54, h 40. Bottom gradient 150 px tall `rgba(14,13,12,0) → #0E0D0C` at 60 %.
- Radius: tiles/buttons/rows 8; dialogs/panels 12; badge 6; pills 18 (h 36).
- Focus ring: `inset −7px; radius 13; border 4px #F0863A; box-shadow 0 0 44px rgba(240,134,58,.55), 0 12px 40px rgba(0,0,0,.6)`; focused tile `scale(1.08)`; buttons `scale(1.04)`. Inside menus use inset −5, 3px border, radius 12. Reduced motion: no scale animation, ring and title emphasis remain.
- Shadows: board/dialog `0 40px 100px rgba(0,0,0,.7)`; toast `0 20px 50px rgba(0,0,0,.5)`.

Artwork (Steam CDN, cached per FR-ART-1): `library_600x900.jpg` cover, `library_hero.jpg` 1920×620, `logo.png`. Placeholder when missing: title on id-derived color.

## Shared chrome (every tab screen)

Top bar: tabs left, flex gap 8. Each tab `h 52, padding 0 22, icon 26 + label, gap 10`. Active: `rgba(243,239,233,.12)` fill, `2px solid rgba(243,239,233,.35)` border, radius 8, label `#F3EFE9` 600; inactive label `#A8A29E` 500. Downloads tab shows a count pill (`#F0863A`, Barlow 600 16, radius 12, padding 5 9) when a job is active. Right cluster: avatar 40 circle + name Barlow 500 24, then clock BC 500 26 `#A8A29E`, gap 22.

Legend (bottom bar): flex gap 30; item = glyph + word gap 10. Face glyph: 36 circle, 2px `#F3EFE9` border, symbol inside. Shoulder/system glyph: h 36 pill, padding 0 10, Barlow 600 15 letter-spacing .04em. Two glyph sets, chosen by connected pad: PlayStation `✕ ○ △ □ L1 R1 L2 R2 OPTIONS PAD PS`; generic `A B Y X LB RB LT RT MENU VIEW GUIDE`. Right side: compact download indicator `h 40, padding 0 16, rgba(243,239,233,.08)`: title, 120×6 bar, `43% · 38 MB/s`.

## Screens

### First run (boards 2e–2h)
Step label top-left BC 600 22 uppercase `Set up · Step n of 4`. Title block at x 96, y 250, width 700–860: 72 px title, 30 px body, gap 34. Right column x ≈ 900–960, width ≤ 924.
- **2e Pair controller**: numbered steps (44 px circle numerals, `rgba(243,239,233,.12)`), "Waiting for a controller…" card with spinner ring (16 px, 3px accent, transparent top). Legend "Continue" at 40 % opacity until a pad connects; right shows keyboard fallback note. Right side 700×560 controller illustration placeholder.
- **2f QR**: 560×560 white (`#F3EFE9`) QR panel, radius 16, padding 36, right column. Status card "Waiting for your phone · code renews in 0:42". Buttons: "Use password instead" (focused), "Skip for now" (outlined, h 64, BC 500 28). Status variants on components sheet: waiting (spinner), approved (green dot, "signed in as Leo"), expired (amber, "getting a new one"), no network (red + "✕ Retry").
- **2g Games volume**: list rows `padding 26 30`, grid `1fr auto`: name BC 600 36, path Barlow 22, 8 px usage bar; right "1.35 TB free / of 2 TB". Selected row `rgba(243,239,233,.10)` + focus ring; others `.04`; read-only volume at 50 % opacity with "Unavailable". Legend: "Use this drive", "Back".
- **2h Preparing**: card 864 wide, padding 30: title "Setting up game runtime" + "2 of 4", 10 px progress bar, step list (done green dot, active spinner, pending 2px `#6B655F` ring). Copy avoids CrossOver/bottle wording except the Settings screen.

### Home (board 1b)
Ambient: focused game's hero blurred 90px at 22 % opacity under a vertical gradient. Rows start y 150, column gap 6 between rows; row = label (BC 600 22 uppercase) gap 14 + tile strip h 400. Tiles 213×320, gap 20, 8 per strip (last clipped; strip scrolls). Rows: Continue playing, Downloading now, Recently installed, Favorites, one per pinned collection; hidden when empty. First tile of first row focused on arrival; focused tile shows title/subtitle below (BC 600 24 + Barlow 16). Tweak: titles under all tiles (off by default).

### Library (boards 2a–2c, 1c)
Rail x 96, w 300: items `padding 16 22`, BC 28 with count right (Barlow 20). Selected item `rgba(243,239,233,.10)` radius 8. Divider then collections. Grid x 444, w 1380, 6 columns of 210×315, gap 24, scrolls vertically; focus keeps column. In the grid the focused tile's title sits inside the tile over a bottom gradient (`padding 40 14 14`) so row pitch is constant.
- **2b Sort & filter**: right sheet w 640 `#16140F`, left hairline, `padding 150 60 110`, backdrop `rgba(14,13,12,.55)`. Groups gap 36: Sort by (Name selected = accent fill), Installed, Genre, Controller support, Compatibility (chips with status dots). Chip h 54, padding 0 20, Barlow 24; "Any" = `.14` fill. Footer: "612 games match" + Reset.
- **2c Search**: field h 64 at grid top, `rgba(243,239,233,.08)` + 2px accent border, magnifier 26, text Barlow 500 30 + 3×34 accent caret; "3 results in All" right; grid moves to y 240. Empty result: reuse 1c layout with "No games match 'xyz'".
- **1c Empty / not signed in**: dashed placeholder grid (2px dashed `.08`/`.05`) under a centered prompt: 56 px title, 26 px body, "Sign in to Steam" (accent, h 72, focused) + "Skip for now". Offline note bottom-right `#6B655F`.

### Game page (board 1e; installed content from 1g)
Hero 1920×620 at top with gradient `rgba(14,13,12,.4) → 0 at 30 % → 0 at 75 % → #0E0D0C`. Back affordance top-left: glyph + "Library"/"Home" (where you came from). Clock top-right. Logo 460×160 `object-fit: contain`, bottom-left of hero at x 96, y 430, drop shadow. Panel from y 640: action row, then two-column body (`1fr 520px`, gap 80).
- Primary button: accent, h 84, padding 0 44, BC 600 38 + size Barlow 22 at 80 %; `scale(1.04)` + white/accent ring when focused (use accent ring B). Labels by state: Install · 8.9 GB / Resume download / Play (with 20×24 triangle) / Return to game.
- Secondary row (h 60, outlined, BC 500 26, `white-space: nowrap`): Favorite (square icon button 60×60 when compact), Add to collection, Hide, Set compatibility, Verify files (installed), Uninstall (installed), View logs. Favorited state: label "Favorited" in accent, icon outlined accent.
- Metadata grid (2 cols, gap 18 40): label BC 600 16 uppercase `#A8A29E` + value Barlow 500 26. Fields: Playtime, Download/Size, Source, Compatibility (badge), Controller, and when installed Last played + "Last session ended cleanly · 1 h 12 min" line with a green dot (crash: red dot, "Last session crashed", toast with View logs).
- Description Barlow 400 26/1.45 `#D6D0C8`, max-width 900–980; tags chips `padding 8 16`, `.10` fill, Barlow 500 20.
- Inline job: when installing, replace the primary button with a progress block using the Downloads active-row content (stage, %, bytes, speed, ETA) and show Pause/Cancel as secondary actions.
- Set-compatibility sheet (not drawn): reuse the right sheet from 2b with the four rating chips and a note field that opens the on-screen keyboard.

### Downloads (board 2d)
Left column x 96, w 1140, sections gap 32 with 22 px uppercase labels. Active card `padding 20`, grid `120px 1fr`: cover 120×180, title BC 600 36, stage `Download · 43%` in accent, 10 px bar, stats row Barlow 22 (`3.8 of 8.9 GB · 38 MB/s · 2 min 14 s left`), stage breadcrumb Barlow 18 (`Estimate › Reserve space › Download › Create bottle › Post-install › Verify`; done `#A8A29E`, current accent, pending `#6B655F`). Focused card has the ring. Queued/recent rows grid `60px 1fr auto`, `padding 14 20`, `.04` fill; cover 60×90; position number right. Failed row: title + red pill `Failed at <stage>` (`rgba(224,90,79,.2)` fill), one-sentence reason, Retry + View logs buttons (h 48). Finished row: green dot + "Installed". Right card x 1300, w 524: storage bar h 16 (games `#F3EFE9`, reserved accent, free `.15`), legend rows, note about pausing while playing. Legend: Pause, "Cancel, move…" (context), Tabs.

### In-game (boards 2i, 2j)
- **Launching**: blurred hero 50px at 50 %, radial dim, centered cover 240×360 with `0 30px 80px` shadow, spinner 26 (4px accent) + "Launching TUNIC…" BC 600 44. Bottom center: `PS` pill + "Hold for one second to quit". Stays until the game's first window; no hang timeout in v1.
- **Exit overlay**: game frame dimmed `rgba(14,13,12,.72)`; dialog 720 wide, `padding 44`, radius 12, `#16140F`, 1px hairline border. Header: cover 64×96 + title BC 40 + "Running · 24 min this session". Buttons stacked h 76: "Return to game" (accent, default focus), "Quit game" (outlined). Footnote `#6B655F` 20/1.4 about the 10 s force-quit. Legend: Select / Return to game (Circle).

### Settings (board 2k)
Rail (same as Library) with Account, Library, Display, Controller, About. Rows `padding 26 30`, grid `1fr auto`: title BC 600 30, subtitle Barlow 22. Controls: outlined button (h 56), disclosure "Change ›", toggle 84×44 (knob 36; on = accent track, knob `#1A1210`). Library section rows shown: Refresh library, Games volume, Download while playing, Runtime (the one place CrossOver/template names appear). Other sections follow PRD 07 FR-SET-1 with the same row pattern.

## Shared components (board 2l)
- **Tile states** (210×315 here, 213×320 on Home): not installed → full-color art + download mark (see "Not-installed treatment" below; the 45 % fade in boards 1a–2l is superseded); queued → top-left badge (`rgba(14,13,12,.85)`, 8 px status dot, Barlow 600 16); downloading → bottom overlay with "Downloading" / % and 6 px accent bar; installed → plain art; running → green "Running" badge; broken → red "Broken" badge; drive disconnected → full-color art + amber badge (no fade). Compatibility badge is not shown on tiles except Broken; it appears on the game page and in filters.
- **Compatibility badges**: `padding 8 14`, radius 6, 2px border tinted with the status color at 50 %, dot 10 + label. Values only: Untested, Works, Playable · note, Broken · note.
- **Context menu**: w 440, `padding 12`, radius 12, `#16140F`; header cover 40×60 + title; items `padding 14 18`, Barlow 500 26; focused item `.10` fill + 3px ring; right-aligned hints (favorite glyph, current rating); hairline before destructive "Uninstall…" in `#E05A4F`. Items: Play/Install, Add to collection, Favorite, Set compatibility, Hide, View logs, Uninstall.
- **Confirm dialog**: w 680, `padding 40`, title BC 600 40, one-sentence consequence Barlow 24/1.4, optional toggle row ("Keep saves", default on), two equal buttons h 68 — Cancel focused by default, destructive button `rgba(224,90,79,.18)` fill + `.5` border.
- **Toasts**: bottom-right, w 560, `padding 18 22`, `#16140F`, status dot 12, title BC 600 24 + detail Barlow 18, optional trailing action in accent (`△ View logs`). Auto-dismiss ~5 s; controller disconnect toast persists until reconnect.
- **On-screen keyboard**: w 1280, `padding 28`, `#16140F`; field h 64; rows centered gap 8; key 96×64 (`.07` fill), modifier 110 (`.14`), space 520, Done 180; Barlow 500 28. Shortcut strip: □ Backspace, △ Space, L1/R1 Cursor, OPTIONS Symbols, ○ Done. Masked mode shows • per character.
- **Log viewer**: full-width overlay; header title `<game> · <job> · <time>` + "n of 10 logs · L1 R1 older/newer"; `<pre>` monospace 19/1.55 `#D6D0C8`, wraps; footer actions: ✕ Retry from <stage>, △ Reveal in Finder, ○ Close.

## Not-installed treatment (board 3b, adopted)
Covers are never dimmed. State is carried by a small mark in the bottom-right corner:
- Mark: 30×30 circle, `background rgba(14,13,12,.8)`, `border 1.5px solid rgba(243,239,233,.5)`, positioned `right 10, bottom 10` inside the tile. Icon: download arrow (line 12,4→12,15 + chevron 6,10 / 12,16 / 18,10 + baseline 5,20→19,20 on a 24 grid) at 16 px, stroke `#F3EFE9` 2.6, round caps. SF Symbol equivalent: `arrow.down.to.line` at 13 pt medium.
- Shown only when `InstallState == notInstalled`. Installed, running, broken and downloading tiles carry no mark (their existing badge/progress overlay applies). Queued and drive-disconnected keep their top-left badge and no fade.
- When the tile is focused the mark stays visible above the title gradient; the focus ring is unchanged.
- Home rows use the same mark at the same size (tile 213×320).
- Rationale: keeps the artwork-led look; the mark reads as "tap to get" from 3 m without lowering contrast. Screenshots: `3b-library-download-glyph.png` (full grid), `3b-tile-detail.png` (3× tile close-up).

## Interactions and motion
- Focus move: ring and scale animate 180 ms ease-out; row/grid scroll follows focus keeping a margin so the ring is never clipped (FR-FOCUS-4). Reduced motion: instant, no scale.
- Hero crossfade on game page arrival 250 ms; ambient blur on Home crossfades to the focused game's hero with a 400 ms delay so quick scrubbing doesn't flicker.
- Held direction repeats at 400 / 120 / 60 ms (FR-IN-1); L2/R2 page a grid by one screen.
- Sheets (filters, compatibility) slide from the right 200 ms; dialogs fade + scale from .96; toasts slide up from bottom-right.
- Modals trap focus; Circle dismisses and restores previous focus.

## State the UI needs (from `Catalog` / `Installs` / `Runner`)
- Per game: `InstallState` (notInstalled, queued, downloading{pct, bytes, speed, eta, stage}, installed, running, failed{stage, reason}, driveDisconnected), `CompatRating` + note, favorite, hidden, collections, playtime, lastPlayed, lastSessionOutcome, sizes, artwork URLs/cache status.
- Global: signed-in identity per source, active job, queue order, storage (used/reserved/free), controller connected + glyph set, current display, reduced motion, offline flag, library sync time.

## Assets
- Art from Steam CDN by app id (`cdn.cloudflare.steamstatic.com/steam/apps/<id>/…`). Titles in the mock: Hades 1145360, Cuphead 268910, A Short Hike 1055540, TUNIC 553420, Celeste 504230, Stardew Valley 413150, Hollow Knight 367520, Disco Elysium 632470, Dead Cells 588650, Slay the Spire 646570, Outer Wilds 753640, Into the Breach 590380, Ori WotW 1057090, Obra Dinn 653530, Inscryption 1092790, Katana ZERO 460950, Spiritfarer 972660, Undertale 391540, Baba Is You 736260, Terraria 105600, Overcooked 2 728880, Castle Crashers 204360, TowerFall 251470.
- Icons: simple 24-grid stroke icons (house, 4-square grid, download arrow, concentric circles); use SF Symbols equivalents (`house`, `square.grid.2x2`, `arrow.down.to.line`, `gearshape`).
- Placeholders to replace: QR panel (render from `SteamAuth` challenge), controller illustration, game descriptions and log text (illustrative), compatibility "Broken" on Spiritfarer (demo only).

## Files
- `GAME_SETTINGS.md` — per-game runtime profile sheet, picker, profile chooser, components job, community banner (boards 4a–4f).
- `screenshots/` — one PNG per artboard at 1920×1080 (components sheet is taller). Files named `<board>-<screen>.png`; `-reference` suffix marks rejected explorations kept for context.
- `Playden.dc.html` — all artboards. Turn 2 (top): 2a–2l. Turn 1 (below): 1a–1g. Ids are anchors (`#2d`).
- `prd/` — the PRD and `GUI_DESIGN_BRIEF.md` these screens implement.
