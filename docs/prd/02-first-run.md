# PRD 02 — First run

Journey: **set up**. From "launched the app on a Mac connected to a TV" to "browsing my library
with a controller". Every step is completable with the controller once it is connected; the first
step is the one exception and is designed for it.

## 1. Display and window

- **FR-DISP-1 (v1):** The app opens fullscreen on the display it was launched on. If more than one
  display is attached, the first-run flow offers a display picker; the choice persists and is
  changeable in Settings.
- **FR-DISP-2 (v1):** UI scales by display size: layouts are specified at 1920×1080 and scale
  proportionally to 4K. Type and focus ring remain legible from 3 m.
- **FR-DISP-3 (v1):** Keyboard arrows and Return/Escape mirror D-pad/Cross/Circle. Cursor visibility
  follows the active input device: mouse movement and clicks reveal the pointer and keep mouse
  interaction usable; keyboard/controller navigation can hide it. Do not capture or lock the mouse.
  Restore normal cursor behavior when the launcher loses focus. Updated after user feedback on
  7 September 2026 about the cursor disappearing during mouse interaction.
- **FR-DISP-4 (later):** Kiosk: launch at login, re-assert fullscreen if another app steals it, keep
  the display awake while a game runs, sleep and wake the Mac from the PS button.

## 2. Controller

- **FR-PAD-1 (v1):** Until a controller is connected, the first-run screen shows how to pair a
  DualShock 4 (Share + PS hold, then macOS Bluetooth). If no controller is connected, the keyboard
  fallback (FR-DISP-3) works so setup is never blocked.
- **FR-PAD-2 (v1):** On connection, a short "press Cross to continue" confirms input. Disconnection at
  any time shows a non-blocking banner; focus state is preserved (03 FR-FOCUS-6).
- **FR-PAD-3 (v1):** DualShock 4 is the tested controller. Any GameController-supported pad works with
  the framework's generic glyphs.
- **FR-PAD-4 (later):** Multiple controllers, player assignment, remapping UI.

## 3. Sign in

- **FR-AUTH-1 (v1):** Steam sign-in is via QR code shown large on the TV, scanned with the Steam
  mobile app (`SteamCore` `SteamAuth` QR path). States: waiting, approved, expired (auto-refresh with
  a new code), network failure with retry.
- **FR-AUTH-2 (v1):** Credentials + Steam Guard is available as a secondary path using the on-screen
  keyboard (03 §5). Password fields are masked.
- **FR-AUTH-3 (v1):** Tokens in Keychain; logout clears them and all cached identity (01 AR-STOR-1).
  One account at a time.
- **FR-AUTH-4 (v1):** "Skip for now" lets the user reach the UI without signing in; the library is
  empty with a sign-in prompt. Once signed in, the library and installed games work offline.
- **FR-AUTH-5 (v2):** Additional sources sign in the same screen through `SourceAuth`; each source
  lists its own state (connected as, disconnected).

## 4. Games volume and bottle template

- **FR-VOL-1 (v1):** First run picks the games volume from mounted writable volumes, showing free
  space. Default per 01 §4. Changeable later in Settings; changing it does not move existing games.
- **FR-TPL-1 (v1):** On first run (or when missing), the app creates the bottle template
  `gn-template-<version>` with `cxbottle --create --template win10_64`, sets MSync on and D3DMetal on,
  and installs nothing else. Creation shows progress; failure names the step (07 §2).
- **FR-TPL-2 (v1):** Template version is pinned in the app. A new template version is created next to
  the old one; existing game bottles are never modified by a template upgrade.
- **FR-TPL-3 (v1):** CrossOver missing or unlicensed is detected up front with a plain message and a
  retry; the library still browses.

## 5. Done state

- **FR-DONE-1 (v1):** After sign-in the app lands on Home (04 §1) with the library loading and artwork
  filling in progressively. Total first run, excluding pairing, under two minutes.
