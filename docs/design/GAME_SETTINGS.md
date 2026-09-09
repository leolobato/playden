# Game settings: per-game runtime profile (boards 4a–4f)

Implements section 1 and 2 of `prd/playden-per-game-settings-profiles-and-a-community-database.md`. Product name shown in UI: **Playden**. Shares every token with `README.md` (colors, type, focus ring B, legend). Demo game: Disco Elysium on the "Older 3D game" profile.

## Entry point
Game page secondary row gains **Game settings** (outlined button, h 60, BC 500 26) right after Favorite. The metadata grid gains a **Profile** field showing the current profile name (Custom shows "Custom · from <base>"). Opening dims the page `rgba(14,13,12,.6)` and slides the sheet in from the right (200 ms).

## Settings sheet (4a, 4b, 4e)
- Sheet: right-anchored, **w 960**, `#16140F`, 1px left hairline `rgba(243,239,233,.1)`, shadow `-40px 0 80px rgba(0,0,0,.5)`. Padding 54 top, 60 sides, 54 bottom. Header: "Game settings" BC 600 44 left, game title Barlow 400 22 `#A8A29E` right, baseline aligned.
- Community banner (v2) sits under the header, above Profile; see 4f. Hidden in v1.
- List: vertical, gap 6, scrolls; bottom 120 px fade to `#16140F`. Footer (fixed): legend ✕ Change · ○ Close on the left; **Reset all to profile** outlined button (h 46, BC 500 22) on the right, `#6B655F` when nothing changed, `#F3EFE9` when the profile is Custom.

Row anatomy (`padding 18 24`, radius 8, grid `1fr auto`, gap 24):
1. Name BC 600 28 `#F3EFE9`. Prefix an 10 px accent dot when the value differs from the profile. Suffix **Changes bottle** tag (Barlow 600 13 uppercase, 1px border `.25`, `#A8A29E`) on Graphics, Synchronization, Windows version.
2. Effect: one sentence, Barlow 400 19/1.3 `#D6D0C8`. Copy from the markdown "What it does" column, trimmed to ≤ 2 lines at 960.
3. "Also called" line: Barlow 400 16 `#6B655F`, label word in `#A8A29E`, then the Lookup names (product names first, then env/registry key).
4. Right: current value Barlow 500 24 (`#F3EFE9`, or `#F0863A` when changed) + `›` in `#6B655F`.
- Background `.04`; focused `.10` + focus ring (inset −6, 4px accent, radius 13, glow `0 0 30px rgba(240,134,58,.45)`).
- Section header ("Settings", "More settings"): BC 600 20 uppercase `.12em` `#A8A29E`, `padding 22 24 10`, optional right hint Barlow 18 `#6B655F` (e.g. "Expanded").

Row order: Profile · [Settings] Graphics, Synchronization, Controller, Windows version, Launch option, Start directly · [More settings, collapsed by default, expands inline] High resolution mode, Virtual desktop, Windows components, Steam features, Language, Performance overlay, Frame limit · [Advanced] Launch arguments, Environment variables, Library overrides (Tier 3: value shows "Empty"/the text; ✕ opens the existing on-screen keyboard; validate with the runner allowlist).

Profile row value = profile name; ✕ opens the chooser (4d). Any change to another row sets Profile to "Custom · from <base>" and marks changed rows with the dot; footer Reset becomes active. Reset all returns every row to the base profile and clears Custom.

## Picker sheet (4c)
Second sheet of the same width slides over the first; the first shifts left 60 px and dims to 60 % brightness. Background `#1A1813`. Header: breadcrumb `○ Game settings` (Barlow 20 `#A8A29E`), setting name BC 600 44 + Changes-bottle tag, effect Barlow 22/1.4, Also-called line Barlow 17. Choices: rows `padding 22 24`, grid `44px 1fr auto`; radio 32 px (selected = accent fill with `#1A1210` check; unselected 2px `.3` border); name BC 600 30 + small tag Barlow 500 16 (`#A8A29E`, or `#E2B53C` for "experimental"); per-choice explanation Barlow 20/1.35 `#D6D0C8`; per-choice technical names Barlow 16 `#6B655F`; right meta Barlow 17 `#6B655F` ("Playden default", "From profile"). Footnote under the list explains the Custom transition and "Applies on next launch". Legend: ✕ Select · ○ Back · △ Reset to profile. Selecting returns to the first sheet.

Use this picker for every enumerated setting. Windows components uses the same layout with checkboxes (multi-select) and a **Install selected** footer action that starts the job (4e).

## Windows components job (4e)
Job card inline under the row: `padding 22 24`, `.08` fill; title BC 600 26 + "n of N" in accent; 8 px progress bar; step list (done green dot, active spinner, pending `#6B655F` ring) with the remaining time on the active step; footnote about the bottle and Play being unavailable. Row value reads "Installing…" in accent. The same job appears on the Downloads screen as a job row. Requires the game to be closed; if running, show the confirm dialog "Quit <game> to install components?".

## Profile chooser (4d)
Full screen over the blurred hero (`blur 70px`, 18 %). Header: `○ Game settings` back, game title right; "Choose a profile" BC 600 56 + one-line explainer Barlow 24 at y 130. Left list x 96, w 640, from y 270: rows `padding 16 22`, name BC 600 28, right hint Barlow 18 `#6B655F` (the "try it when" in 3–4 words); **Current** tag on the active profile; Custom is listed last in `#A8A29E`. Right panel x 820, w 1004, `rgba(22,20,15,.9)`, radius 12, `padding 34 40`: profile name BC 600 40; "Try it when" paragraph Barlow 22/1.4 (label in `#A8A29E`); comparison table grid `1fr 200px 30px 200px`: Setting · Current · → · This profile; changed rows tinted `rgba(240,134,58,.08)` with accent arrow and `#F3EFE9` new value, unchanged rows keep `#6B655F`. Summary line counts changes and names bottle-level ones. Legend: ✕ Use this profile · ○ Back · △ Save current as my profile (v1: writes a JSON profile to the games volume `Playden/profiles/<slug>.json`; export/import UI not drawn).

Profiles are data: ship `profiles.json` in the app bundle with `id, name, tryWhen, shortHint, settings{}`; the chooser renders from it. Community recipes use the same shape plus `reports{works, total, crossoverMajor, likeMine}`.

## Community banner (4f, v2)
Placed above the Profile row. Three states, all `padding 18 22`, radius 8, 12 px status dot, title BC 600 24, sub Barlow 18/1.3:
- **No reports**: `.04` fill, `.08` border, grey dot, no action.
- **Recipe available**: `rgba(240,134,58,.1)` fill, `.35` accent border, green dot, title "Community recipe: worked for N of M on CrossOver 26", sub names the base profile, change count and "reports from Macs like yours"; **Apply** accent button (h 46).
- **Applied**: `.06` fill, `.12` border, green dot, "Using the community recipe", **Revert** outlined button.

## Toast on close
When the sheet closes with pending changes: bottom-right toast (see components sheet) with accent dot, "Settings saved · <profile>", "n changes apply on next launch". No per-row "applies on next launch" text.

## Data
`RuntimeProfile { base: profileId | null, overrides: {settingId: value}, source: 'default'|'profile'|'user'|'community', appliedAt }`. Resolved value per setting = user override ?? profile value ?? Playden default; the UI compares resolved vs profile value to draw the dot. Graphics, Synchronization, Windows version write to the game's bottle on next launch, never the template.

## Screenshots
`4a-game-settings-tier1.png`, `4b-game-settings-custom-tier2.png`, `4c-picker-graphics.png`, `4d-profile-chooser.png`, `4e-components-job.png`, `4f-community-banner-states.png`.

## Implementation decisions
See "Decisions for the first implementation" at the end of the PRD. In short: no Language row, Windows components deferred, Start directly lists launch entries only, no "Changes bottle" tag (nothing in v1 writes to the bottle), community banner and profile export deferred.
