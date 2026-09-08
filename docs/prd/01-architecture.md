# PRD 01 — Architecture

Engineering shape the requirements assume. Changing this file changes what the other files can
promise, so decisions here are dated.

## 1. Process model

- **AR-PROC-1 (v1):** One macOS app process. UI, downloads, bottle management and game supervision run
  in it. Downloads and jobs are persisted so a restart resumes them (05 FR-INST-6).
- **AR-PROC-2 (v2):** A background helper (LaunchAgent, XPC) owns downloads, bottle jobs and game
  supervision. The UI becomes a client. Enabled by AR-MOD-3 below: the UI only ever talks to the
  `Installs` and `Runner` protocols, so relocation does not touch screens.
- **AR-PROC-3 (v1):** Apple Silicon only. macOS minimum is whatever CrossOver 26 and GameController
  DualShock support require; pin the exact version at first build.

## 2. Modules

One Xcode app target plus SwiftPM library modules. Each module is testable without the UI.

| Module | Responsibility | Depends on |
|---|---|---|
| `BigScreenApp` | SwiftUI views, AppKit window management (fullscreen borderless window on the chosen display, cursor hidden), wiring | everything below |
| `Input` | GameController framework wrapper. Emits semantic `InputAction`s (see 03 §1), hold-repeat, stick deadzone, connect/disconnect events, per-pad glyph names | Foundation, GameController |
| `Focus` | Spatial focus engine: containers (rail, grid, row, menu), per-container last-focused memory, directional resolution, edge hand-off | Foundation only |
| `Catalog` | The library model and its persistence: `Game`, `InstallState`, `Collection`, `PlaySession`, `CompatRating`, user edits (favorite, hidden, note) | GRDB (SQLite) |
| `Sources` | `GameSource` and `Installer` protocols; `SteamSource` + `SteamInstaller` (v1) | `SteamCore` (in-repository `Packages/SteamKit`) |
| `Runner` | `GameRunner` protocol; `CrossOverRunner`: bottle template, create/copy/delete via `cxbottle`, launch via `cxstart`, process observation | Foundation |
| `Installs` | Job orchestrator: install/uninstall/verify jobs, serial queue, persistence, pause/cancel | `Sources`, `Runner`, `Catalog` |
| `Artwork` | Fetch and cache cover/hero/logo/icon per game; Steam CDN (v1), SteamGridDB (v2) | Foundation |

- **AR-MOD-1 (v1):** Dependency direction is as in the table and nothing else. `Focus` and `Input` know
  nothing about games. `Catalog` knows nothing about Steam or CrossOver. `Sources` and `Runner` know
  nothing about UI.
- **AR-MOD-2 (v1):** `SteamCore` is imported only inside `Sources`. No other module names a Steam type.
- **AR-MOD-3 (v1):** The UI depends on `Installs` and `GameRunner` as protocols and receives them by
  injection, so v2's helper can substitute XPC proxies.

## 3. The three protocols

Sketch, not final signatures. Async throwing Swift; progress via `AsyncStream`.

```swift
protocol GameSource {                       // a store or account
    var id: SourceID { get }                // "steam", "gog", "itch", "epic", "manual"
    var displayName: String { get }
    var auth: any SourceAuth { get }        // login (QR / credentials / none), logout, identity
    func ownedGames() async throws -> [GameRecord]
    func metadata(for game: GameRecord) async throws -> GameMetadata
    func installer(for game: GameRecord) -> any Installer
}

protocol Installer {                        // how a game becomes launchable
    func estimate() async throws -> InstallEstimate                 // download bytes, disk bytes
    func install(to dir: URL) -> AsyncThrowingStream<InstallProgress, Error>   // pause/resume/cancel aware
    func postInstall(_ g: InstalledGame, in bottle: Bottle) async throws       // Steam: gbe_fork staging, Steamless
    func verify(_ g: InstalledGame) async throws -> VerifyResult
    func uninstall(_ g: InstalledGame) async throws                 // source-side cleanup only
    func launchSpec(for g: InstalledGame) -> LaunchSpec             // exe, args, env, dllOverrides, workingDir
}

protocol GameRunner {                       // where a game runs
    func prepare(for g: InstalledGame) async throws -> Bottle       // create bottle from template if missing
    func launch(_ spec: LaunchSpec, in bottle: Bottle) async throws -> RunningGame
    func observe(_ r: RunningGame) -> AsyncStream<RunState>          // launching, running, exited(status)
    func terminate(_ r: RunningGame, force: Bool) async throws
    func destroy(_ bottle: Bottle) async throws
}
```

- **AR-PROTO-1 (v1):** `SteamSource`/`SteamInstaller` and `CrossOverRunner` are the only implementations.
- **AR-PROTO-2 (v2):** Second source (GOG or itch.io). **(later):** Epic, `ManualSource` (point at an exe).
- **AR-PROTO-4 (v2):** Add optional native macOS launch and official Steam macOS installation
  discovery, preserving separate ownership and runtime choices per game (05 §7).
- **AR-PROTO-3 (later):** A second runner (a VM-based runtime) is possible because
  `LaunchSpec` carries no CrossOver-specific fields.

## 4. Storage layout

| What | Where |
|---|---|
| Database, artwork cache, per-game config JSON, job state, logs | `~/Library/Application Support/Big Screen/` |
| Steam tokens | Keychain (v1). `SteamCore`'s file `TokenStore` is acceptable only while the Keychain adapter is unbuilt. |
| Game files | User-chosen games volume, default `/Volumes/VM/Big Screen/games` if present, else `~/Games/Big Screen`. Layout `<source>/<gameId>/<Name>/`, compatible with `SteamCore`'s `app_<appid>/<Name>/` for Steam. |
| Bottles | CrossOver's private bottle directory, named `gn-<source>-<gameId>`, so they are visible and deletable in CrossOver's own UI. |
| Bottle template | Bottle `gn-template-<version>`; see 02 §4. |

- **AR-STOR-1 (v1):** Nothing identity-derived (SteamID, tickets) is written outside the Keychain and
  the gbe_fork staging area inside a game's own directory.
