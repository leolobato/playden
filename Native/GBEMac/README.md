# gbe_fork for macOS (`libsteam_api.dylib`)

Playden replaces Valve's `libsteam_api.dylib` in Steam macOS game bundles with
a build of [gbe_fork](https://github.com/Detanup01/gbe_fork), so the games run
without the Steam client (docs/prd/08-stores.md, FR-SMAC-6/7 and decision 12).
Upstream has no macOS support (issue #189). This directory holds everything
needed to build it:

| Path | What it is |
|---|---|
| `../../scripts/build-gbe-macos.sh` | Fetches the pinned sources, builds both architectures, `lipo`s, signs and checks the result |
| `CMakeLists.txt` | Replaces upstream's premake `api_regular` project for macOS |
| `patches/*.patch` | Source changes for macOS/clang, applied in order with `git apply` |
| `src/voicechat_stub.cpp` | Replaces `dll/voicechat.cpp` (voice chat compiled out) |
| `test/` | Smoke test: `gbe_smoke.c` and `run-test.sh` |

The shipped binary is
`Packages/SteamKit/Sources/SteamCore/Resources/steampipe/libsteam_api.dylib`;
its hashes and pins are in `steampipe/PROVENANCE.md`.

## Rebuild

```sh
./scripts/build-gbe-macos.sh --test --install   # ~2 min from scratch on an M-series Mac, ~30 s after
```

- `--clean` deletes the build tree first; `--test` runs `test/run-test.sh` on
  both architectures; `--install` copies the result into the SteamCore
  resources. The script prints the SHA-256 at the end. Record it in
  `PROVENANCE.md`.
- The build tree is `.build/gbe-macos` (git-ignored). Set `GBE_BUILD_DIR` to
  put it somewhere else. Dependencies are cached per architecture and rebuilt
  only when their options change. The gbe_fork checkout is reset to the pinned
  commit and re-patched on every run.
- Needs Xcode (clang, SDK, `lipo`, `codesign`), `cmake` ≥ 3.24 and network
  access. Homebrew is only a source of `cmake`: the script clears
  `CPATH`/`LIBRARY_PATH`/`PKG_CONFIG_PATH` and tells CMake to ignore
  `/opt/homebrew`, `/usr/local` and `/opt/local`. The script fails if the result
  links anything outside `/usr/lib` and `/System`.
- Output: universal `arm64` + `x86_64`, minimum macOS 11.0, install name
  `@loader_path/libsteam_api.dylib` (compatibility and current version 1.0.0),
  ad-hoc signed.
- The build is reproducible: build-tree paths are mapped out with
  `-ffile-prefix-map`, and `EMU_BUILD_STRING` is fixed
  (`playden-macos-<commit>`), not a date. Two build trees give the same SHA-256
  with the same Xcode.

### What is pinned

| Source | Version | Where from |
|---|---|---|
| gbe_fork | `73a7349deb660f689d3358179b76eca039178f73` (branch `dev`, 2026-09-25) | `git fetch` of that commit |
| protobuf | v34.1 | upstream's `third-party/deps/common` branch at `92a4a130…`, SHA-256 checked |
| mbedtls | v3.6.6 | same |
| libssq | v3.0.1 | same |
| abseil-cpp | 20250512.1 (the version protobuf 34.1 pins) | GitHub tag tarball, SHA-256 checked |
| libcurl, zlib | system (`/usr/lib/libcurl.4.dylib`, `/usr/lib/libz.1.dylib`) | macOS SDK |

protobuf, abseil, mbedtls and libssq are built from source for each
architecture with the same options as upstream's `premake5-deps.lua`, and linked
statically with hidden visibility. Upstream lets protobuf `git clone` abseil at
configure time. We point `FETCHCONTENT_SOURCE_DIR_ABSL` at the pinned tarball
instead. `protoc` is built only for the host architecture and generates
`proto_gen/macos`.

Upstream builds curl 8.20 against mbedtls, plus zlib. We use the SDK's curl and
zlib instead. gbe_fork only uses the basic `curl_easy_*` API (for
`ISteamHTTP`), and the system curl uses the macOS TLS stack and trust store.
mbedtls is still needed directly, for RSA signing of app tickets (`auth.cpp`).

## What is compiled out

| Feature | Why | Effect |
|---|---|---|
| Experimental build / in-game overlay (`EMU_EXPERIMENTAL_BUILD`, `EMU_OVERLAY`, `ingame_overlay`) | We build upstream's *regular* flavour, as for Linux. The overlay hooks Windows/Linux graphics APIs. | No Shift+Tab overlay. `ISteamFriends::ActivateGameOverlay*` do nothing, as in the regular Linux build. |
| Voice chat (opus, portaudio) | If a game opens the microphone without `NSMicrophoneUsageDescription` in its Info.plist, TCC kills the process. It is also off by default upstream (`enable_voice_chat=0`). | `ISteamUser::GetVoice`/`GetAvailableVoice`/`DecompressVoice` return `k_EVoiceResultNotInitialized` (`src/voicechat_stub.cpp`). |
| Controller support (`CONTROLLER_SUPPORT`, `libs/gamepad`) | `gamepad.c` has only XInput and Linux evdev back ends. | `ISteamController`/`ISteamInput` report no controllers. Games that read controllers themselves (GameController.framework, SDL, Unity Input) are not affected. |
| `dll/wrap.cpp` | Linux-only `--wrap` file hooks for case-insensitive paths. It is `#if __LINUX__`, so it compiles to nothing. | None. APFS is case-insensitive by default. |
| SDL3 | Only used by the overlay/controller paths above. | None. |

Everything else from the regular build is in, including LAN multiplayer,
lobbies, stats, achievements, leaderboards, cloud (local), UGC/mods,
inventory, `ISteamHTTP`, source query (libssq), app tickets and the crash
printer.

## Patches

Each patch has a comment header that explains it. Each change in the source
is marked `[Playden macOS]` and guarded by `__MACOS__`/`__APPLE__` (or
`EMU_NO_VOICECHAT`), so Linux and Windows builds are unchanged.

1. `0001-macos-posix-includes.patch`: `common_includes.h` had branches only for
   `__WINDOWS__` and `__LINUX__`. macOS now takes the Linux branch, without
   `<linux/netdevice.h>`/`<sys/vfs.h>` and with the Darwin headers.
   `MSG_NOSIGNAL` is defined as 0. The debug-log thread id comes from
   `pthread_threadid_np`.
2. `0002-macos-exe-and-lib-paths.patch`: `_NSGetExecutablePath` replaces
   `/proc/self/exe`. The `dladdr()` library path is enabled on macOS and
   resolved with `realpath()`. `getcwd`/`realpath` replace the glibc-only
   `get_current_dir_name`/`canonicalize_file_name`. `load_dlls` looks for
   `.dylib`.
3. `0003-macos-networking.patch`: `getifaddrs()` collects the LAN broadcast
   addresses (the Linux `SIOCGIFCONF` walk is wrong on BSD). `SO_NOSIGPIPE` is
   set on every TCP socket, because macOS has no `MSG_NOSIGNAL`.
4. `0004-macos-libc-and-save-dir.patch`: `gmtime` replaces `gmtime_s`, and the
   unused `<ucontext.h>` is skipped. The default save root is
   `~/Library/Application Support` instead of `~/.local/share`.
5. `0005-voicechat-optional.patch`: with `EMU_NO_VOICECHAT`, `voicechat.h`
   does not include opus/portaudio.

To update gbe_fork, change `GBE_COMMIT` (and `GBE_DEPS_COMMIT`/`DEPS` if the
submodule pointer moved) in the build script. Then run it: `git apply` stops
on the first patch that no longer applies. Rebase that patch on a checkout of
the new commit and regenerate it with `git diff`. Keep the comment header.

## Where gbe_fork looks for `steam_settings` on macOS

The rule is the same as on Linux and Windows. The files go **next to the
library**, not next to the executable:

```
<directory that contains libsteam_api.dylib>/steam_settings/
```

- The directory comes from `dladdr()` on a function inside the dylib. On macOS
  the path is then resolved with `realpath()`. The result is the real file's
  directory, whatever `@rpath`/`@loader_path`/`@executable_path` the game used,
  and after following symlinks. For a symlinked dylib, `steam_settings` must be
  next to the symlink's *target*. Playden replaces the file in place, so this
  does not apply.
- Examples: `Game.app/Contents/Frameworks/libsteam_api.dylib` →
  `Game.app/Contents/Frameworks/steam_settings/`. For Unity,
  `Game.app/Contents/Plugins/libsteam_api.dylib` →
  `Game.app/Contents/Plugins/steam_settings/`. For a bundle with more than one
  copy, each copy reads its own `steam_settings`.
- The executable directory and the working directory are **not** searched for
  `steam_settings/`. (`test/run-test.sh` runs from another cwd and checks
  this. With `steam_settings/` only next to the executable, gbe_fork falls
  back to its defaults: a random Steam ID and the account name "gse orca".)
- Override: the environment variable `GseAppPath=<dir>` replaces the
  library directory.
- App ID order: the env vars `SteamAppId`, `SteamGameId` and
  `SteamOverlayGameId` (values other than 0/1) → `steam_settings/steam_appid.txt`
  → `./steam_appid.txt` in the cwd → `steam_appid.txt` next to the dylib → the
  argument of `SteamAPI_RestartAppIfNecessary(appid)`, used only if nothing
  else gave an app ID. Playden should always write
  `steam_settings/steam_appid.txt`, and should not set a conflicting
  `SteamAppId` in the game's environment.
- Files read from `steam_settings/`: `configs.user.ini`, `configs.main.ini`,
  `configs.app.ini`, `configs.overlay.ini`, `steam_appid.txt`, `DLC`/`depots`/
  `achievements.json`/`stats.json`/`steam_interfaces.txt` and so on, the same
  as on Windows and Linux. The Windows staging data can be reused unchanged.

### Save data and global settings

- The save root is `~/Library/Application Support/GSE Saves/`
  (`$XDG_DATA_HOME/GSE Saves/` if that is set). Game saves go in
  `<root>/<appid>/`. gbe_fork also writes `<root>/settings/configs.user.ini`
  with the account name, Steam ID and language, even when `steam_settings`
  has them. When `steam_settings` has no account, it reads that file back as
  the fallback.
- `[user::saves] local_save_path=<path>` in `configs.user.ini` (relative
  paths are resolved against the dylib directory), or the env var
  `GseSavePath`, moves all of this. When a local save path is set, the global
  settings are ignored. Playden should set `local_save_path` so that saves are
  kept per game and are not stored inside the game bundle.

## Test

```sh
Native/GBEMac/test/run-test.sh [path/to/libsteam_api.dylib]   # default: the shipped copy
```

The script compiles `gbe_smoke.c` as a universal binary and copies the dylib
to `$tmp/Game.app/Contents/Frameworks/`, with `steam_settings/`
(`steam_appid.txt`, `configs.user.ini`, `configs.main.ini`, `configs.app.ini`)
next to it. `HOME` is a temporary directory and the cwd is somewhere else.
For each architecture in the dylib (x86_64 through `arch -x86_64` under
Rosetta; skipped with a message if Rosetta is missing), and with both
`SteamAPI_InitFlat` and legacy `SteamAPI_Init`, `gbe_smoke` does the following:

1. It `dlopen`s the library and checks that `SteamAPI_RestartAppIfNecessary`
   returns false.
2. It starts the API and checks `SteamAPI_ISteamUser_GetSteamID`, `BLoggedOn`,
   `SteamAPI_ISteamUtils_GetAppID` and `SteamAPI_ISteamFriends_GetPersonaName`
   against the files.
3. It runs `SteamAPI_RunCallbacks` for 1 s and then calls `SteamAPI_Shutdown`.

Last, the script checks that nothing was written to the cwd, to `HOME` or next
to the executable.

## Known gaps

- Only the smoke test has been run so far, not a real game. S4 must check a
  real game, including a Unity one (`Contents/Plugins`).
- The replacement dylib is ad-hoc signed. A hardened-runtime game with library
  validation will not load it until the bundle is re-signed ad hoc
  (FR-SMAC-7). That signature has no `--options runtime`, which turns library
  validation off.
- Valve's library also has an i386 slice, for 32-bit games that no current
  macOS can run. We ship only arm64 and x86_64.
- All 1078 symbols exported by the Valve `libsteam_api.dylib` we checked (SDK
  with `SteamUser023`/`SteamClient021`) are exported, plus about 200 more from
  gbe_fork for older and newer SDKs. A game built with a newer SDK than
  gbe_fork knows can still need symbols that gbe_fork does not implement.
- The Steam Input / controller API and voice are stubs (see above).
