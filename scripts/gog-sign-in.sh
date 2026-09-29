#!/bin/zsh
# Signs in to GOG and saves .gog-session.json for the live tests.
#   scripts/gog-sign-in.sh                 prints the login URL
#   scripts/gog-sign-in.sh '<address>'     saves the session from the address the login ends on (or its code)
#   scripts/gog-sign-in.sh check           refreshes the session and writes .gog-library.tsv
set -eu
cd "$(dirname "$0")/.."
run() { swift run --package-path Packages/GOGKit -c release gog-dev "$@"; }
case "${1:-}" in
  "") echo "Sign in at this URL in any browser, then run this script again with the address you land on (in quotes):"; run url ;;
  check) run check "$PWD/.gog-session.json" "$PWD/.gog-library.tsv" ;;
  *) run sign-in "$PWD/.gog-session.json" "$1" ;;
esac
