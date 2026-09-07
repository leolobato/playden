#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
app='DerivedData/Build/Products/Debug/Big Screen.app'
if [[ ! -d "$app" ]]; then
  ./scripts/build.sh
fi
open "$app" --args "$@"
