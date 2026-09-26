#!/bin/bash
# Smoke-test a gbe_fork libsteam_api.dylib on every architecture it contains.
#
# Usage: Native/GBEMac/test/run-test.sh [path/to/libsteam_api.dylib]
#   default: Packages/SteamKit/Sources/SteamCore/Resources/steampipe/libsteam_api.dylib
#
# Lays the library out like a game bundle, with steam_settings/ next to it:
#   $tmp/Game.app/Contents/Frameworks/libsteam_api.dylib
#   $tmp/Game.app/Contents/Frameworks/steam_settings/{steam_appid.txt,configs.*.ini}
# and runs the harness from a different working directory, so the test also
# proves that gbe_fork finds steam_settings next to the dylib (not next to the
# executable or in the current directory). x86_64 runs under Rosetta.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
DYLIB="${1:-$REPO_ROOT/Packages/SteamKit/Sources/SteamCore/Resources/steampipe/libsteam_api.dylib}"
DYLIB="$(cd "$(dirname "$DYLIB")" && pwd)/$(basename "$DYLIB")"

APPID=480
STEAMID=76561197960287930
NAME="Playden Tester"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gbe-smoke.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fw="$tmp/Game.app/Contents/Frameworks"
mkdir -p "$fw/steam_settings" "$tmp/Game.app/Contents/MacOS" "$tmp/cwd" "$tmp/saves" "$tmp/home"
cp "$DYLIB" "$fw/libsteam_api.dylib"

echo "$APPID" >"$fw/steam_settings/steam_appid.txt"
cat >"$fw/steam_settings/configs.user.ini" <<EOF
[user::general]
account_name=$NAME
account_steamid=$STEAMID
language=english

[user::saves]
local_save_path=$tmp/saves
EOF
cat >"$fw/steam_settings/configs.main.ini" <<'EOF'
[main::connectivity]
# keep the test hermetic: no LAN broadcast / listen sockets. (Not offline=1,
# which would make ISteamUser::BLoggedOn() return false.)
disable_networking=1
EOF
cat >"$fw/steam_settings/configs.app.ini" <<'EOF'
[app::general]
build_id=1
EOF

bin="$tmp/Game.app/Contents/MacOS/gbe_smoke"
xcrun clang -Wall -Wextra -O1 -mmacosx-version-min=11.0 -arch arm64 -arch x86_64 \
  -o "$bin" "$HERE/gbe_smoke.c"

rosetta=false
if arch -x86_64 /usr/bin/true 2>/dev/null; then rosetta=true; fi

status=0
for a in $(lipo -archs "$fw/libsteam_api.dylib"); do
  echo "=== $a"
  if [[ "$a" == x86_64 && "$(uname -m)" == arm64 && "$rosetta" == false ]]; then
    echo "SKIP x86_64: Rosetta 2 is not installed"
    continue
  fi
  for mode in "" --legacy-init; do
    echo "--- ${mode:-SteamAPI_InitFlat}"
    # Clear anything that would make gbe_fork take the app ID or paths from the
    # environment, and point HOME at the temp dir so nothing reaches the real
    # ~/Library/Application Support/GSE Saves.
    if ! (cd "$tmp/cwd" && env -u SteamAppId -u SteamGameId -u SteamOverlayGameId \
          -u GseAppPath -u GseSavePath -u XDG_DATA_HOME HOME="$tmp/home" \
          arch "-$a" "$bin" "$fw/libsteam_api.dylib" \
          "$APPID" "$STEAMID" "$NAME" $mode); then
      status=1
    fi
  done
done

# With a complete steam_settings/ and local_save_path, gbe_fork must not write
# to the working directory, next to the executable, or under HOME.
for d in "$tmp/cwd" "$tmp/home" "$tmp/Game.app/Contents/MacOS"; do
  extra="$(cd "$d" && find . -mindepth 1 ! -name gbe_smoke)"
  if [[ -n "$extra" ]]; then
    echo "FAIL unexpected files in $d:"; echo "$extra"; status=1
  fi
done
echo "save data written to local_save_path:"
(cd "$tmp/saves" && find . -mindepth 1 | sed 's/^/  /')
[[ $status == 0 ]] && echo "ALL PASSED"
exit $status
