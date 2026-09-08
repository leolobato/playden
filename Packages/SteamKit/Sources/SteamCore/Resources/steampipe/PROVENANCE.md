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
