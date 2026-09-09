# Playden: Per-Game Settings, Profiles and a Community Database

Proposal for which CrossOver options Playden should expose per game, which ready-made profiles it should ship, and how a community database of "what works" could be built. Written against Playden 0.1, CrossOver 26.x, Apple Silicon.

## Summary and recommendation

Playden today makes two CrossOver choices for every game in the bottle template (MSync on, D3DMetal on) and lets the user change only two things per game: the controller mode and the preferred Steam launch option. Everything else that decides whether a game runs is fixed or hidden.

Recommendation, in three steps:

1. **Introduce a per-game "runtime profile."** One document that holds every setting below. Values resolve in layers: Playden defaults, then a chosen profile, then the user's own overrides. The profile is stored next to the install record and applied on the next launch.
2. **Ship a small set of curated profiles** (section 2) so most fixes are one selection on the couch, not a dozen toggles.
3. **Build the community database on that same document.** A report is the profile plus what happened. Playden already knows the CrossOver version, the Mac, the game build, playtime and exit results, so a report costs the user one button press.

Expose settings in three tiers. Tier 1 is always visible in Game settings. Tier 2 sits behind "More settings." Tier 3 is text entry meant to be filled by a profile or a community recipe rather than typed with a controller.

## 1. Configurable settings on Playden

Every entry has the name Playden would show, what it does in plain words, and the name it has in CrossOver or Wine so people can search for it. "Lookup" lists the terms that find the right forum threads and documentation.

### The names you will see

Guides, forum posts and the tables below use a handful of technical names. This is what each one is, in gamer terms. Playden should show these same explanations in the app, one sentence at a time, next to the setting.

**The basics**

- **Wine** is the software that runs Windows games on a Mac without Windows. When the game asks Windows for something, Wine answers in the Mac's language instead. It is a translator, not an emulator, so games run at close to full speed.
- **CrossOver** is the paid, polished version of Wine made by CodeWeavers. It adds the Mac gaming pieces below and a support team that fixes games. Playden drives CrossOver behind the scenes.
- **A bottle** is a self-contained fake Windows installation: its own C: drive, settings and registry. Playden gives every game its own bottle, so a fix for one game can never break another.
- **Registry** is Windows' settings database. Many Wine switches live there. You never edit it in Playden, but guides mention registry keys, so the tables list them.

**Graphics**

- **DirectX** is the graphics system Windows games are written for. **Metal** is the Mac's. Every Windows game on a Mac needs something to translate DirectX into Metal, and the choice of translator is the single biggest factor in whether a game runs well.
- **D3DMetal** is Apple's own translator for DirectX 11 and 12. It came from Apple's Game Porting Toolkit and CrossOver bundles it. Usually the fastest option for modern games, and Playden's default.
- **DXVK** is a translator built by the Linux gaming community. It turns DirectX 9, 10 and 11 into **Vulkan**, another graphics system, and on the Mac a layer called **MoltenVK** turns Vulkan into Metal. That extra step costs some speed, but DXVK is very mature and fixes many visual bugs, especially in older games.
- **DXMT** is a newer community translator that turns DirectX 11 straight into Metal, skipping the Vulkan step. Often faster than DXVK and it renders some games correctly where D3DMetal has glitches. CrossOver marks it experimental.

**Speed and stability**

- **MSync and ESync** are speed boosts. Games run many tasks at once and those tasks constantly wait for each other. Wine's original way of handling that waiting is slow. **ESync** ("event sync") is a faster method. **MSync** ("Mach sync") is a newer Mac-only method that is faster still. Both are on by default and both occasionally confuse a game into hanging, which is why a switch exists.
- **Windows version** is the Windows edition Wine claims to be. Some older games check for Windows 7 and refuse to start on anything newer.
- **Large address aware** lets a 32-bit game use more than 2 GB of memory. Old games with big mods, or that crash after an hour, often need it.
- **CPU topology** hides some of the Mac's cores from the game. A few games misbehave when they see many cores or mixed performance and efficiency cores.

**Display**

- **High Resolution Mode**, called **Retina Mode** in Wine, decides whether the game sees your screen's full pixel count (3840×2160 on a 4K TV) or a halved size that macOS scales up. On is sharper and heavier. Off is softer and faster.
- **Virtual desktop** makes Wine draw a fake Windows desktop of a fixed size and run the game inside it. Games that fight with macOS fullscreen, or that change your TV's resolution, behave better in it.

**Controllers**

- **WineBus** is the part of Wine that tells the game which controllers are plugged in.
- **hidraw** is WineBus's direct mode. With it on, the game sees your real DualShock or DualSense and its extra features. With it off, Wine presents the pad as a generic Xbox controller, which nearly every PC game supports. Playden's "Xbox compatible" is hidraw off.

**Libraries and components**

- **DLL** is a Windows library file, a chunk of shared code games load at start. Wine ships its own version of almost every Windows DLL. A **DLL override** tells Wine, for one library, to use the game's copy instead of Wine's, or to ignore it. In guides `n,b` means "try the game's copy first, then Wine's."
- **Windows components**, also called **redistributables** or "redists," are shared libraries most games need but do not include: the Visual C++ runtime, .NET, older DirectX files. On Windows, Steam installs them silently before the first launch from a folder named `_CommonRedist`. Playden does not run Steam, so it has to install them itself.
- **winetricks** is a community script that installs those components into a bottle. Its shorthand names, like `vcrun2022` or `dotnet48`, appear in almost every guide, so the tables list them as search terms.
- **Environment variables** are named on/off switches set before the game starts, written like `WINEMSYNC=1`. Most CrossOver tips online are given in this form.

**Steam and overlays**

- **GBE Fork**, the Goldberg Steam Emulator fork, is a stand-in for the Steam client that runs inside the bottle. The game thinks Steam is present, so it starts, shows your name, and sees your DLC. It works offline only. Playden uses it so the real Steam app never has to run in the bottle.
- **Launch options** are the extra words typed after a game's executable, like `-windowed`. Steam has the same box under a game's Properties.
- **Metal HUD** is macOS's built-in performance overlay for Metal games: frames per second, GPU time. **DXVK HUD** is DXVK's own version of it.
- **Media Foundation** is Windows' video player. Wine's copy is incomplete, so in-game videos and cutscenes are the most common thing to break. The "cutscenes fail" issue tag in section 3 points at it.
- **Anti-cheat** systems such as Easy Anti-Cheat and BattlEye work at the Windows kernel level. Wine cannot provide that, so games that require them do not run under CrossOver at all.

### Tier 1: always visible

| Playden setting | What it does | Choices | Lookup (CrossOver / Wine name) |
|---|---|---|---|
| **Graphics** | Picks the translator that turns the game's DirectX graphics into the Mac's Metal. This decides whether most games render at all, and how fast. | Default (D3DMetal, Apple's, fastest for new games) · DXVK (community, most accurate for old games) · DXMT (community, experimental, fixes some DX11 glitches) | **D3DMetal**, **DXVK**, **DXMT**. Bottle setting `CX_GRAPHICS_BACKEND` in `cxbottle.conf`. |
| **Synchronization** | A speed boost for how the game's many tasks wait for each other. The fastest mode makes a few games hang or crash. Switching it is the second thing to try after Graphics. | Default (MSync, fastest, Mac-only) · ESync (fast, older) · Off (slowest, most compatible) | **MSync** (`WINEMSYNC=1`), **ESync** (`WINEESYNC=1`). |
| **Controller** | How the game sees your pad. "Xbox compatible" presents it as a standard Xbox controller, which most games expect. "Native" passes it through as a DualShock or DualSense, for games that support them directly. | Xbox compatible · Native | **hidraw**, **WineBus**. Registry `HKLM\System\CurrentControlSet\Services\WineBus\DisableHidraw`. |
| **Windows version** | Which Windows the game is told it runs on. Older games sometimes refuse to start on "Windows 10." | Windows 10 · Windows 8.1 · Windows 7 | **Windows Version** in CrossOver bottle settings; `winecfg`. |
| **Launch option** | Which of the game's launch entries to start. Many games ship separate DirectX 11 and DirectX 12 executables, or a "skip launcher" entry, as launch options. | From the game's Steam launch options | Steam **launch options** (`appinfo` launch config). |
| **Start directly** | Skip the game's own launcher window and start the game executable. Fixes launchers that hang, show a blank window, or want a browser. | Off · Pick executable | No CrossOver name. Common tips: **"skip launcher"**, **"bypass launcher"**, `cxstart` executable path. |

### Tier 2: behind "More settings"

| Playden setting | What it does | Choices | Lookup |
|---|---|---|---|
| **High resolution mode** | Renders at the display's full pixel count instead of a scaled size. On a 4K TV this makes text and HUDs sharp but costs performance. Turn it off for speed. | On · Off | **High Resolution Mode** (CrossOver), **Retina Mode** (Wine Mac driver). Registry `HKCU\Software\Wine\Mac Driver\RetinaMode`. |
| **Virtual desktop** | Runs the game inside a fixed-size Windows desktop instead of taking over the screen. Rescues games that break in fullscreen, change the TV resolution, or vanish when the display sleeps. | Off · 1920×1080 · 2560×1440 · 3840×2160 | **Emulate a virtual desktop** (`winecfg` Graphics tab). Registry `HKCU\Software\Wine\Explorer\Desktop`. |
| **Windows components** | Installs the runtime libraries the game expects Windows to have. Steam normally installs these silently. Playden does not run Steam, so a game may fail with no message until they are installed. | Checklist: Visual C++ 2015–2022 · .NET Framework 4.8 · DirectX (June 2010) · XAudio · PhysX · Run the game's own installers | Steam `installscript.vdf` and **`_CommonRedist`**. CrossOver installers **"Microsoft Visual C++ Redistributable"**, **"DirectX for Modern Games"**, **".NET Framework 4.8"**. Wine equivalents: **winetricks** `vcrun2022`, `dotnet48`, `d3dx9`, `xact`, `physx`. |
| **Steam features** | Options of the built-in Steam emulator: unlock all DLC the game checks for, hide the Steam overlay, and the account name shown in game. Offline mode is always on in this version. | Unlock DLC · Overlay on/off · Account name | **GBE Fork** (Goldberg Steam Emulator fork) `steam_settings`: `configs.app.ini` (DLC), `configs.overlay.ini`, `configs.user.ini`. |
| **Language** | Which language the game runs in. Already recorded at install time. | Steam languages the game offers | Steam depot **language**; GBE `configs.user.ini` `language`. |
| **Performance overlay** | Shows a frames-per-second counter and GPU load in the corner while playing. Useful when writing a community report. | Off · On | **Metal HUD** (`MTL_HUD_ENABLED=1`). For DXVK: **DXVK HUD** (`DXVK_HUD=fps`). |
| **Frame limit** | Caps frames per second. Steadier on a 60 Hz TV and cooler laptop. DXVK only in this version. | Off · 30 · 60 · 120 | `DXVK_FRAME_RATE`. |

### Tier 3: advanced (text entry)

These are typed, imported from a profile, or filled from a community recipe. Playden should validate them the same way the runner validates the launch spec today, with an allowlist of environment keys and a strict override format.

| Playden setting | What it does | Lookup |
|---|---|---|
| **Launch arguments** | Extra text passed to the game executable. Common ones: `-windowed`, `-dx11`, `-nolauncher`, `-skipintro`. | Steam **launch options**, `cxstart` arguments. |
| **Environment variables** | Named switches read by CrossOver, Wine or the graphics layer at start. Allowlisted keys only. | `cxbottle.conf` **`[EnvironmentVariables]`**. Useful keys: `WINE_LARGE_ADDRESS_AWARE=1` (lets 32-bit games use more than 2 GB), `WINE_CPU_TOPOLOGY=8:0,1,2,3,4,5,6,7` (hide cores from games that choke on many cores), `DXVK_ASYNC=1`, `D3DM_SUPPORT_DXR=1` (ray tracing under D3DMetal; verify on CrossOver 26). |
| **Library overrides** | Tells Wine to use the game's own copy of a Windows library, or to ignore it. Fixes crashes in input, audio and shader libraries and in web-based launchers. | **DLL overrides** (`winecfg` Libraries tab), `WINEDLLOVERRIDES`, `cxstart --dll`. Common: `winmm=n,b`, `dinput8=n,b`, `xinput1_3=n,b`, `d3dcompiler_47=n`, `libglesv2=d` (Electron and CEF launchers), `nvapi=d`. |

### Placement and interaction rules

- Every setting shows "Default" as its first choice and states what the default is. Clearing a setting returns to the profile value, then to Playden's value.
- A changed setting shows "Applies on next launch," matching how controller mode works today.
- Graphics, Synchronization and Windows version change the bottle. Playden should write them to the game's bottle, never to the template.
- Windows components run installers inside the bottle and need the game closed. Show them as a job with progress, like Verify files.
- Tier 3 fields are read-only on the couch when empty and editable with a keyboard. When filled from a profile or recipe, show the source ("From community recipe, 12 reports").

## 2. Predefined profiles based on the community

A profile is a named bundle of Tier 1 to Tier 3 values. Users pick one, then override single settings. These are the bundles the Mac gaming community keeps converging on in AppleGamingWiki pages, CodeWeavers forum threads and Whisky and GPTK guides. Playden should ship them and label each with when to try it.

| Profile | Try it when | Settings |
|---|---|---|
| **Playden default** | Every game starts here. | D3DMetal · MSync · Windows 10 · Xbox compatible controller · High resolution on. |
| **Modern DX12** | Recent DirectX 12 games that stutter, show corrupted shadows or crash under the default. | D3DMetal · MSync · Windows 10 · `D3DM_SUPPORT_DXR` off · frame limit 60 · high resolution off. |
| **DX11 alternative** | DirectX 11 games with flicker, missing effects or a black screen under D3DMetal. | DXMT · MSync · Windows 10. Fallback inside the profile: DXVK if DXMT fails to start. |
| **Older 3D game** | DirectX 9 or 10 games from roughly 2005 to 2013. | DXVK · ESync · Windows 7 · Virtual desktop 1920×1080 · `WINE_LARGE_ADDRESS_AWARE=1` · Windows components: DirectX (June 2010), Visual C++ 2010 to 2013, XAudio. |
| **Unity or Unreal launcher** | Games that open a small settings window first and then hang or never start. | Start directly at the game executable · `-nolauncher` where the engine honors it · Playden default for the rest. |
| **Web-based launcher** | Store launchers built on Electron or Chromium that show a blank white window. | `libglesv2=d` · `d3dcompiler_47=n` · Windows components: Visual C++ 2015–2022. |
| **Hides too many cores** | Games that stutter or crash on start on M-series Pro, Max and Ultra chips. | `WINE_CPU_TOPOLOGY=8:0,1,2,3,4,5,6,7` on top of the default. |
| **Native DualSense** | Games with real DualShock or DualSense support (adaptive triggers, touchpad). | Controller: Native · rest from default. |

Profiles are data, not code. Ship them as a JSON file inside the app so an update can add or fix a profile without a release, and so a community recipe (section 3) can be expressed in the same format and shown as "Community profile for this game."

## 3. Community database

### What already exists

No source today is both specific to CrossOver on Apple Silicon and usable by a program. Each one covers a part.

| Source | Platform | Machine usable | What it offers |
|---|---|---|---|
| **CodeWeavers Compatibility Center** | CrossOver | No | Star ratings per app and CrossOver version, free-text "Tips & Tricks," forum threads. The scripted CrossTie recipes were retired. |
| **AppleGamingWiki** | Mac: CrossOver, GPTK, Whisky, Parallels | Partly | Per-game ratings (Perfect, Playable, Runs, Unplayable), notes and comments. Data lives in MediaWiki Cargo tables reachable through the wiki API. Licensed CC BY-NC-SA, so it can be linked and queried but not copied into a product. The best existing Apple Silicon source. |
| **PCGamingWiki** | All | Partly | Launch options, config file and save locations, known fixes. The save locations already matter for Playden's Steam Cloud mapping. Cargo API as well. |
| **ProtonDB** | Linux, Steam Deck | Partly | User reports with structured "tinker" tags (launch options, custom Proton, winetricks) and free text. Monthly JSON dumps on GitHub. Launch options and library overrides often carry over to CrossOver. |
| **Lutris installers** | Linux | Yes | YAML recipes with Wine version, DXVK, esync, library overrides, environment and winetricks steps. The closest existing format to a Playden recipe. Public API per game slug. |
| **Are We Anti-Cheat Yet** | Linux | Partly | Which games use Easy Anti-Cheat or BattlEye. Those do not run under CrossOver, so this alone can warn a user before a 60 GB download. |

The gap Playden can fill: a database of recipes keyed by Steam AppID for CrossOver on Apple Silicon, fed by a launcher that already knows the configuration and the outcome.

### What a report should carry

Most fields are filled by Playden without asking. The user adds a rating and, optionally, a note.

**Game identity**

- Source and AppID.
- Depot manifest IDs of the installed build (already stored in the install record). A recipe that worked on one build may break on the next.
- Launch option used, and the executable if "Start directly" was on.
- Game language.

**Host**

- CrossOver version.
- macOS version.
- Chip family and tier (M1 to M4; base, Pro, Max, Ultra).
- Unified memory size.
- Playden version and bottle template version.

**Recipe**

- The full runtime profile from section 1, including the profile name it was based on, installed Windows components and controller mode.

**Outcome**

- Rating on Playden's existing scale: Works, Playable, Broken. Untested is never reported.
- Stage reached: starts, reaches menu, in game, completed.
- Issue tags: crash on start, black screen, cutscenes fail (Media Foundation video is a frequent one), audio crackle, controller not detected, launcher stuck, shader stutter, online or DRM blocked, anti-cheat.
- Performance: resolution, in-game quality preset, rough frames-per-second band (under 30, 30 to 60, over 60).
- Playtime under this exact recipe. Playden records sessions, so this is automatic and is the strongest evidence a recipe holds up.

**Provenance**

- Report date.
- A salted hash of the account for deduplication. The SteamID itself never leaves the Mac, consistent with the architecture rule that nothing identity-derived is written outside the Keychain.

### Aggregation and trust

- Group reports by AppID and CrossOver major version. A recipe is shown as "worked for N of M reports on CrossOver 26."
- Weight reports by playtime under the recipe. One session of 20 hours outweighs five one-minute launches.
- Prefer the smallest recipe that works. If the default profile has 30 Works reports, do not surface a complex recipe with 3.
- Show disagreements. Different chips and memory sizes explain most conflicting reports, so the game page filters by "Macs like mine."
- Anti-cheat presence is a hard flag shown before download, not a rating.

### Phasing

- **v1 (now):** Store the runtime profile per game. Ship curated profiles. Capture the outcome fields locally with each play session. This is useful on its own and produces well-formed reports later.
- **v2:** "Share report" on the game page uploads the report. The game page shows community ratings and offers "Apply community recipe" as one press.
- **Later:** Apply the best community recipe automatically at install time, with a visible "Recommended by the community" tag and a one-press revert. Import anti-cheat flags and PCGamingWiki save locations into the install flow.

### Open questions

- Hosting and moderation of the database. A static JSON export on GitHub with pull-request review is enough for v2 and needs no server.
- Whether to link AppleGamingWiki pages from the game screen in v1 as a stopgap. It costs one URL per game and gives users the notes that exist today.
- License of contributed recipes. Suggest CC0 for recipes and outcome data so other Mac launchers can consume them, which grows the pool of reports faster than any single app.

## Decisions for the first implementation (2026-09-09)

Agreed while planning the v1 slice on branch `feat/game-settings`. Boards 4a–4e in `docs/design/GAME_SETTINGS.md` are the target; the community banner (4f) and every section-3 feature stay out of this slice.

**Scope**

- Ship the settings sheet, the picker, the profile chooser, the close toast and the Tier 3 text rows. Work lands as one branch with one commit per slice: data model and profiles, runner application, Steam options and launch resolution, app model, sheet, picker, chooser, text entry, docs.
- The existing controller-mode dialog and the Launch options panel are replaced by the sheet. "Launch options" leaves the More menu. No backwards compatibility with the two per-game values stored so far; they become part of the runtime profile.
- Curated profiles ship as `profiles.json` in the app bundle, as proposed in section 2. "Save current as my profile" (chooser △) is deferred with the export and import UI.

**Settings dropped or deferred**

- **Language**: not shown. Installs are English only today and a language change means new depot downloads. Revisit with multi-language installs.
- **Windows components**: deferred. CrossOver 26 has no command-line installer for redistributables, and Playden only runs installers that ship inside a game's own depot through pinned per-game recipes. Later options, in order: (A) "Run the game's own installers" driven by `installscript.vdf` and `_CommonRedist`, with the rest of the checklist shown disabled; (B) Playden downloads the Microsoft redistributables from pinned URLs with pinned hashes, winetricks style, cached on the games volume.
- **Start directly**: not shown. Restricted to the game's launch entries it is the same choice as Launch option, so one row covers both. An executable browser over the install folder can bring the row back later.
- **Steam features**: only the overlay toggle ships. "Unlock all DLC" is not exposed: it makes the emulator claim every DLC as owned regardless of the account, and the depots only contain owned DLC, so it is an ownership bypass rather than a compatibility fix. The account name shown in game stays the fixed string "Playden".
- **Large address aware** becomes a visible Tier 2 row (On · Off) at the end of More settings so the profile comparison table can show it and users can toggle it without typing.

**How settings apply**

- A probe on CrossOver 26.2 showed that the process environment does not override `[EnvironmentVariables]` in the bottle's `cxbottle.conf`. Graphics and Synchronization therefore rewrite three keys in the game's bottle before launch (`CX_GRAPHICS_BACKEND`, `WINEMSYNC`, `WINEESYNC`), only when they differ and only while the bottle is idle. The template is never modified, and the bottle readiness check accepts the allowed values instead of demanding the template's. These two rows keep the "Changes bottle" tag.
- Windows version uses the `--winver` launch flag and does not change the bottle.
- Controller, High resolution mode and Virtual desktop are registry values, applied before every launch as one registry import followed by a wineserver restart of the idle bottle, the way controller mode works today.
- Performance overlay, Frame limit and Large address aware are environment variables passed at launch. Tier 3 environment variables and library overrides are validated by the runner's existing allowlist and override format; keys that Playden manages itself cannot be typed.
