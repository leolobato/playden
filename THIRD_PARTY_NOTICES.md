# Third-party notices

Playden is Copyright (C) 2026 Leonardo Lobato and is licensed under the GNU General Public
License, version 3 or (at your option) any later version. See [LICENSE](LICENSE).

This file lists the third-party code and assets that Playden derives from, links against or
ships unmodified, with their licenses. Where a component is under a copyleft license, its terms
apply regardless of whether it is named here.

## Source offer for copyleft components

For every LGPL or GPL component distributed in binary form with Playden, the corresponding source
is available from the upstream project at the revision recorded below. If you cannot obtain it
from upstream, open an issue at <https://github.com/leolobato/playden/issues> and it will be
supplied, in accordance with GPL-3.0 section 6 and LGPL-3.0 section 4. This offer is valid for at
least three years from the date you received the binary.

---

## GameNative and Pluvia (GPL-3.0)

- **Projects:** [GameNative](https://github.com/utkarshdalal/GameNative) by Utkarsh Dalal and
  contributors, which descends from [Pluvia](https://github.com/oxters168/Pluvia) by oxters168
  and contributors.
- **License:** GNU General Public License v3.0.
- **Where:** `Packages/SteamKit/Sources/SteamCore`.

Parts of `SteamCore` are Swift ports of Kotlin code from GameNative at commit
`d8535825398afb1446d63f95ba53698cf1586847`: Steam API interface extraction and DLL replacement
(`SteamUtils.kt`), the stats and achievements generator and its binary VDF parser
(`statsgen/`), PICS key-value parsing (`KeyValueUtils.kt`), the encrypted app-ticket request and
cache behavior (`SteamService.kt`), and the `AppInfo`, `UFS`, `SaveFilePattern` and `PathType`
data shapes. Playden is a derivative work of that code and is distributed under the same
license.

## gbe_fork (LGPL-3.0)

- **Project:** [gbe_fork](https://github.com/Detanup01/gbe_fork), a fork of the Goldberg Steam
  Emulator by Mr_Goldberg.
- **License:** GNU Lesser General Public License v3.0.
- **Where:** `Packages/SteamKit/Sources/SteamCore/Resources/steampipe/steam_api.dll` and
  `steam_api64.dll`, shipped unmodified. The build is the one bundled by GameNative at file
  commit `08d2db098917ae029e4a4acccb73f37f8f699434`; SHA-256 values are recorded in
  `PROVENANCE.md` next to the files. Playden does not link against these libraries; they are
  copied into a game's own folder at preparation time and loaded by the game.

## Steamless (CC BY-NC-ND 4.0)

- **Project:** [Steamless](https://github.com/atom0s/Steamless) by atom0s, release v3.1.0.5.
- **License:** Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International. The
  full text is preserved as `Packages/PlaydenKit/Sources/Sources/Resources/Steamless/LICENSE`.
- **Where:** `Packages/PlaydenKit/Sources/Sources/Resources/Steamless`, shipped unmodified and
  run as a separate program inside a game's CrossOver bottle. It is aggregated with Playden, not
  linked into it.

Steamless is not free software. Redistributing Playden together with the bundled Steamless
release is limited to noncommercial use, and the Steamless files may not be modified. See
[docs/STEAMLESS.md](docs/STEAMLESS.md) for the pinned release and hashes.

## GRDB.swift (MIT)

- **Project:** [GRDB.swift](https://github.com/groue/GRDB.swift) by Gwendal Roué.
- **License:** MIT. Copyright (C) 2015-2025 Gwendal Roué.
- **Where:** Swift package dependency of `PlaydenKit`.

## SwiftProtobuf (Apache-2.0)

- **Project:** [swift-protobuf](https://github.com/apple/swift-protobuf) by Apple Inc. and the
  Swift project authors.
- **License:** Apache License 2.0.
- **Where:** Swift package dependency of `SteamKit` and `PlaydenKit`.

## Steam protocol definitions

- **Project:** [SteamDatabase/Protobufs](https://github.com/SteamDatabase/Protobufs).
- **License:** The upstream repository declares no license. The `.proto` files describe the
  Steam network protocol and are the same definitions used by SteamKit2, JavaSteam and
  GameNative.
- **Where:** `Packages/SteamKit/protos/steam` and the generated Swift in
  `Packages/SteamKit/Sources/SteamProto/Generated`. One local patch is documented in
  `Packages/SteamKit/protos/regen.sh`.

## xz (liblzma) and zstd

- **Projects:** [xz](https://tukaani.org/xz/) (liblzma, 0BSD) and
  [zstd](https://github.com/facebook/zstd) (BSD-3-Clause, dual licensed with GPL-2.0).
- **Where:** Linked from the Homebrew installations through the `CLzma` and `CZstd` targets in
  `SteamKit`. Not redistributed in this repository.

## CrossOver

[CrossOver](https://www.codeweavers.com/crossover) is proprietary software by CodeWeavers, Inc.
Playden does not bundle or link against it. It invokes the `cxbottle`, `cxstart` and `wine`
command-line tools of the user's own installation. The Windows display helper in
`Native/DisplayHelper` is Playden's own code and uses only Windows system libraries.

## Trademarks

Playden is an independent project and is not affiliated with Valve Corporation or CodeWeavers,
Inc. Steam is a trademark of Valve Corporation. CrossOver is a trademark of CodeWeavers, Inc.
