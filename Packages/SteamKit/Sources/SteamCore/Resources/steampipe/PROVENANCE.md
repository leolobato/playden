# gbe_fork Steam API assets

These are exact lifts from the surveyed Android checkout
`../GameNative-android` at
`d8535825398afb1446d63f95ba53698cf1586847`:

| Resource | Android path | File commit | SHA-256 |
|---|---|---|---|
| `steam_api.dll` | `app/src/main/assets/steampipe/steam_api.dll` | `08d2db098917ae029e4a4acccb73f37f8f699434` | `4cc9dfcab8b4df0db507fa91d0acec6e58693fd4edd78dc80d39bda8072d08ed` |
| `steam_api64.dll` | `app/src/main/assets/steampipe/steam_api64.dll` | `08d2db098917ae029e4a4acccb73f37f8f699434` | `513430ac8b869b0eed258d9e5feba5176a35446b3b61a63d01ab1d87683cdd1b` |

They are the same Android-bundled gbe_fork DLLs used by
`SteamUtils.replaceSteamApi`; SwiftPM copies the directory into the
`SteamCore` resource bundle unchanged.

## macOS: `libsteam_api.dylib`

Built by Playden from gbe_fork source. Upstream ships no macOS binaries (see
`Native/GBEMac/README.md` for the port, what is compiled out, and the
`steam_settings` location rule).

| | |
|---|---|
| File | `libsteam_api.dylib`, universal `x86_64` + `arm64`, minimum macOS 11.0 |
| SHA-256 | `756cd4f86ec030f4e66014a4dae35ff7ee60a8eaa500d18cd210c04d05950249` |
| Install name | `@loader_path/libsteam_api.dylib` (compat/current 1.0.0), the same as Valve's |
| Links | `/usr/lib/libcurl.4.dylib`, `/usr/lib/libz.1.dylib`, `/usr/lib/libc++.1.dylib`, `/usr/lib/libSystem.B.dylib`, `CoreFoundation.framework` |
| Signature | ad hoc (`codesign --force --sign -`) |
| Upstream | https://github.com/Detanup01/gbe_fork `73a7349deb660f689d3358179b76eca039178f73` (branch `dev`), regular (non-experimental) flavour |
| Build command | `./scripts/build-gbe-macos.sh --test --install` |
| Toolchain | Xcode 26.3, macOS SDK 26.2, CMake 3.30.3 |

Dependencies, statically linked and built from source for each architecture.
The tarballs come from upstream's `third-party/deps/common` branch at
`92a4a130262083c4e887155cbe6bcab99baf36ea`, except abseil:

| Dependency | Version | Tarball SHA-256 |
|---|---|---|
| protobuf | v34.1 | `1f29cfcd40dbb033ebd7680e42ddefb22fdc3e5ac1c37a4f09d4931cbfae7ba1` |
| abseil-cpp | 20250512.1 (GitHub tag archive) | `9b7a064305e9fd94d124ffa6cc358592eb42b5da588fb4e07d09254aa40086db` |
| mbedtls | v3.6.6 | `27133c38f383738d8ba0f0d86b52226f1ef3a48da32fed1a2e306b8ded66b6d8` |
| libssq | v3.0.1 | `e92860f8ff94e04485174b6e075fac8dd56a5ebacbb245ccee0d8104fa3074f4` |
| libcurl 8.7.1, zlib | macOS system libraries (not bundled) | n/a |

Patches applied (`Native/GBEMac/patches/`):
`0001-macos-posix-includes`, `0002-macos-exe-and-lib-paths`,
`0003-macos-networking`, `0004-macos-libc-and-save-dir`,
`0005-voicechat-optional`, plus `Native/GBEMac/src/voicechat_stub.cpp`.

Compiled out: the in-game overlay (experimental flavour), voice chat, and
Steam Input controller support.

The build is reproducible: two clean build trees gave the SHA-256 above. It
exports all 1078 symbols of a Valve macOS `libsteam_api.dylib`
(`SteamUser023`/`SteamClient021` SDK) on both architectures, 1282 in total,
all of them Steam API.
