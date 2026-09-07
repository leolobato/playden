# PRD 03 — Navigation, input and focus

Applies to every screen. The controller is the only input that matters; the keyboard fallback exists
for development.

## 1. Semantic actions

`Input` maps hardware to these actions; screens bind behavior to actions, never to buttons.

| Action | DualShock 4 | Keyboard (dev) | Meaning |
|---|---|---|---|
| `move(.up/.down/.left/.right)` | D-pad, left stick | arrows | Move focus |
| `confirm` | Cross | Return | Activate focused item |
| `back` | Circle | Escape | Go back / dismiss |
| `context` | Triangle | T | Context menu for focused game |
| `favorite` | Square | F | Toggle favorite on focused game |
| `options` | Options | O | Screen-level sort and filters |
| `tabPrev` / `tabNext` | L1 / R1 | [ / ] | Switch top-level tab |
| `pagePrev` / `pageNext` | L2 / R2 | PgUp / PgDn | Jump a page in a grid or list |
| `search` | Touchpad click | / | Open search |
| `home` | PS (short) | Home | Return to launcher / Home |
| `holdHome` | PS (hold 1 s) | Shift+Home | In-game exit overlay (06 §2) |

- **FR-IN-1 (v1):** Stick deadzone and eight-way digitization; a held direction repeats after 400 ms,
  then every 120 ms, then every 60 ms after 1.5 s.
- **FR-IN-2 (v1):** A button legend at the bottom of every screen lists the actions available there
  with the current pad's glyphs.
- **FR-IN-3 (v1):** Input is ignored while a game is running except `holdHome` (06 FR-INGAME-2).
- **FR-IN-4 (later):** Remapping; alternative pads' glyph sets beyond GameController defaults.

## 2. Focus engine

- **FR-FOCUS-1 (v1):** Focus is a tree of containers: `rail` (vertical list), `grid`, `row`
  (horizontal), `menu`. Leaves are focusable items. Exactly one leaf is focused at a time.
- **FR-FOCUS-2 (v1):** Directional resolution: within a container pick the nearest item in that
  direction by center distance with axis preference; when moving between rows in a grid keep the
  column; at an edge hand off to the parent, which chooses the neighbor container and restores its
  last-focused child.
- **FR-FOCUS-3 (v1):** Every container remembers its last focused child for the life of the screen;
  Home rows and the Library grid also remember across tab switches.
- **FR-FOCUS-4 (v1):** Scrolling follows focus, keeping the focused item fully visible with a margin;
  rows scroll horizontally, grids vertically. Focus never lands off-screen.
- **FR-FOCUS-5 (v1):** Modal overlays (dialogs, keyboard, context menu) trap focus; `back` dismisses
  and restores the previous focus.
- **FR-FOCUS-6 (v1):** Controller disconnect freezes focus; reconnect resumes at the same item.
- **FR-FOCUS-7 (v1):** Focused item is visibly distinct without color alone: scale, ring and title
  emphasis. Reduced-motion setting disables the scale animation.

## 3. Layout

- **FR-LAY-1 (v1):** Persistent top bar: tabs Home, Library, Downloads, Settings, plus account and
  time. Tabs switch with L1/R1 from anywhere except inside a modal.
- **FR-LAY-2 (v1):** Bottom bar: button legend (FR-IN-2) and a compact downloads indicator when a
  job is running.
- **FR-LAY-3 (v1):** Safe area: 5% inset on all sides for TV overscan.

## 4. Overlays

- **FR-OVL-1 (v1):** Context menu for a game (Triangle): Play/Install, Add to collection, Favorite,
  Hide, Uninstall, Properties (v2), Set compatibility. Destructive items require a confirm dialog.
- **FR-OVL-2 (v1):** Confirm dialog: title, one-sentence consequence, two buttons; Circle cancels.
- **FR-OVL-3 (v1):** Toasts, bottom-right, auto-dismiss: download complete, install failed, controller
  connected/disconnected, low battery (v2).

## 5. On-screen keyboard

- **FR-KBD-1 (v1):** Controller-navigable QWERTY with shift, symbols, space, backspace, done.
  Square = backspace, Triangle = space, L1/R1 = cursor, Options = toggle symbols, so common edits do
  not require travelling the grid.
- **FR-KBD-2 (v1):** Search field filters live as characters are entered.
- **FR-KBD-3 (v1):** Masked mode for passwords and Steam Guard codes.
- **FR-KBD-4 (later):** Companion typing from a phone.
