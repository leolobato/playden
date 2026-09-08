#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
app='DerivedData/Build/Products/Debug/Playden.app/Contents/MacOS/Playden'
if [[ ! -x "$app" ]]; then
  ./scripts/build.sh
fi
"$app" --snapshot "${PLAYDEN_SNAPSHOT_DIR:-$PWD/.build/screenshots}" "$@"
