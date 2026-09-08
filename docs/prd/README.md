# Playden — PRD

Product requirements for a couch-first game launcher on macOS. This folder is the contract for
*what the product is*, split by user journey. Engineering detail lives in
[01-architecture.md](01-architecture.md) and, for the Steam layer,
[SteamKit](../../Packages/SteamKit/README.md).

Drafted 2026-09-07 (Leo + Claude brainstorm). Decisions recorded below are dated; everything else is
proposal-stage until built.

The [v1 implementation plan](../IMPLEMENTATION_PLAN.md) translates this PRD into delivery milestones,
including proposed corrections and planning defaults from the implementation review. Those proposals
are identified separately from the dated decisions below.

The [implementation plan](../IMPLEMENTATION_PLAN.md) records delivery and acceptance criteria.
v1 is still in progress; this PRD remains the
requirements contract, not a claim that every requirement has passed acceptance.

## Product in one sentence

A fullscreen, controller-only launcher that shows your game libraries on the TV, installs Windows
games into their own CrossOver bottles, and plays them, so the Mac under the TV behaves like a
console.

## Who it's for

- **Leo, on the couch.** A PS4 controller in hand, a Mac on the TV, a Steam library of ~600 games.
  Wants to pick a game and play without touching a keyboard, mouse or the CrossOver window.
- **Later: other players on Macs.** Same expectations; may use other stores and controllers.

## Release tiers

Every requirement carries one tag. A requirement without a tag is a bug in this PRD.

| Tag | Meaning |
|---|---|
| **v1** | The MVP: "install and play from the couch". Ships first. |
| **v2** | "A real living-room console": properties, overlays, a second store, background helper. |
| **later** | Known and wanted, not scheduled. |

## Decisions (dated 2026-09-07)

1. **Install model: direct downloads.** Game files are downloaded directly by the app (Steam depots via
   `SteamCore`), Steam emulation (gbe_fork) provides the Steam API, and the game exe is launched in
   CrossOver. The real Steam client is never shown. Alternative rejected: driving the Steam client in a
   bottle, because it surfaces Steam's own windows and takes install control away from the launcher.
2. **Standalone app that reuses `SteamCore`.** New SwiftUI/AppKit app in this repository, depending on
   the in-repository `SteamKit` SwiftPM package. This product ships on its own timeline and does
   not carry the research VM runtime.
3. **Stores and installers are protocols from day one.** `GameSource` and `Installer` are defined in v1
   with Steam as the only implementation; GOG, itch.io and Epic follow (see [05-install.md](05-install.md)).
4. **One CrossOver bottle per game, cloned from a launcher-managed template.** Isolation per title,
   uninstall is "delete the bottle", per-game settings are natural. Alternative rejected: one shared
   bottle, because one title's registry or runtime tweaks can break another.
5. **Single app process with its own spatial focus engine.** Controller input (GameController
   framework) drives a custom focus model; SwiftUI's built-in macOS focus is not designed for gamepad
   grid navigation. Downloads and game supervision run in-process in v1 behind protocols, so v2 can move
   them into a background helper without touching the UI.
6. **Home screen is in v1.** It is the landing screen. (Leo, 2026-09-07.)
7. **Background helper is v2, not later.** (Leo, 2026-09-07.)

## Journeys and document map

| Doc | Journey | Covers |
|---|---|---|
| [01-architecture.md](01-architecture.md) | (engineering) | Modules, the `GameSource`/`Installer`/`GameRunner` protocols, storage layout, dependency rules |
| [02-first-run.md](02-first-run.md) | **Set up** | Display, controller, QR login, games volume, bottle template |
| [03-navigation.md](03-navigation.md) | (every journey) | Controller mapping, focus engine behavior, layout, on-screen keyboard, overlays |
| [04-library.md](04-library.md) | **Find a game** | Home, Library, collections and filters, search, game page, compatibility, artwork |
| [05-install.md](05-install.md) | **Install a game** | Source and installer protocols, install pipeline, downloads queue, bottles, uninstall, storage |
| [06-play-session.md](06-play-session.md) | **Play** | Launch, in-game behavior, exit, playtime, crash handling |
| [07-settings-diagnostics.md](07-settings-diagnostics.md) | **Fix something** | Settings, failure contract, logs, testing strategy |

## MVP bar (v1 success criteria)

v1 ships when, with the Mac connected to a TV and only a PS4 controller in hand:

- From a fresh install, the user pairs the controller, signs into Steam by scanning a QR code, and sees
  their full owned library with artwork on the Home and Library screens.
- The user installs a known-good title (initial list: Cuphead, A Short Hike, TUNIC; revised as titles
  are verified in CrossOver) and reaches player-controlled gameplay without a keyboard or mouse.
- Quitting the game, from the game's own menu or from the launcher's exit overlay, returns to the
  launcher with playtime recorded.
- Every install or launch failure lands in a visible state with the failing stage named. No silent
  hangs.
- A launcher restart in the middle of a download resumes it.
- A verified Steam Cloud title downloads an existing cloud save before launch and uploads changed
  saves after exit. Offline play, failed-sync retry and conflicting local/remote changes preserve
  the user’s progress and expose a controller-accessible recovery path. See 05 §6.

## v1 non-goals

- Any store other than Steam (protocols exist; implementations do not).
- Per-game properties editing beyond the compatibility badge and note (v2).
- In-game overlay beyond the exit prompt (v2).
- Kiosk behaviors: auto-launch at login, owning the display, sleep/wake from the controller (later).
- Controllers other than a DualShock 4 for the tested path. Other GameController-supported pads work
  with generic glyphs; remapping UI is later.
- Achievements UI, DLC management, multiplayer or anti-cheat titles.
- Native macOS game versions and integration with the official Steam macOS installation (v2).
- Intel Macs. Distribution and notarization polish.

## Dependencies

| PRD area | Depends on |
|---|---|
| Login, library, downloads, gbe_fork staging | `SteamCore` in `Packages/SteamKit` (auth, PICS, CDN download engine, `Prepare`), already implemented and CLI-tested |
| Launch | CrossOver 26.x installed; `cxbottle` and `cxstart` CLIs (verified present 2026-09-07) |
| Artwork | Steam CDN public art endpoints; SteamGridDB API key for v2 fallback |
| Controller | Apple GameController framework (DualShock 4 supported natively) |

## Glossary

- **Bottle**: a CrossOver Wine prefix with its own registry, drive C and settings.
- **gbe_fork**: the open Steam API emulator that replaces `steam_api(64).dll` so games run without the
  Steam client. "Mode A staging" is the `SteamCore` procedure that installs and configures it.
- **Steamless**: tool that unpacks SteamStub DRM from an exe once so it can run under emulation.
- **Focus engine**: the component that decides which on-screen element is highlighted and where a
  directional press moves it.
- **Source**: a store or account that owns games (Steam, GOG, itch.io, Epic, or "Manual").
- **Installer**: the per-source procedure that puts a game's files on disk and makes them launchable.
- **Runner**: the component that launches and supervises a game process (CrossOver in v1).
