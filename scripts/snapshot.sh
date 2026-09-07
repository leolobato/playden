#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
app='DerivedData/Build/Products/Debug/GameNative Big Screen.app/Contents/MacOS/GameNative Big Screen'
if [[ ! -x "$app" ]]; then
  ./scripts/build.sh
fi
"$app" --snapshot "$PWD/.build/screenshots"
