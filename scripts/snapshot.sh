#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
app='DerivedData/Build/Products/Debug/Big Screen.app/Contents/MacOS/Big Screen'
if [[ ! -x "$app" ]]; then
  ./scripts/build.sh
fi
"$app" --snapshot "${BIGSCREEN_SNAPSHOT_DIR:-$PWD/.build/screenshots}" "$@"
