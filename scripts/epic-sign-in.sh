#!/bin/zsh
# Signs in to Epic with a code (finish on your phone) and saves .epic-session.json for the live tests.
# `scripts/epic-sign-in.sh check` refreshes the saved session and lists the library instead.
set -eu
cd "$(dirname "$0")/.."
swift run --package-path Packages/EpicKit -c release epic-dev "${1:-sign-in}" "$PWD/.epic-session.json"
