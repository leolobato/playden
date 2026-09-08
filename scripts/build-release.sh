#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

reveal=true
case "${1:-}" in
  --no-open) reveal=false; shift ;;
  --help|-h)
    printf 'Usage: ./scripts/build-release.sh [--no-open]\nBuild a local Release app and reveal it in Finder for copying to Applications.\n'
    exit 0
    ;;
esac
if (( $# != 0 )); then
  printf 'Unknown argument: %s\n' "$1" >&2
  exit 1
fi

./scripts/build.sh --release
derived_data="${PLAYDEN_DERIVED_DATA_PATH:-DerivedData}"
if $reveal; then
  open -R "$derived_data/Build/Products/Release/Playden.app"
fi
