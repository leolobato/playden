#!/bin/zsh
set -eu
if (( $# < 2 || $# > 3 )); then
  print -u2 'Usage: scripts/benchmark-steam-install.sh EXISTING_FIXTURE_PARENT OUTPUT_JSON [ITERATIONS=3]'
  exit 2
fi
export PLAYDEN_STEAM_BENCHMARK_ROOT="${1:a}"
export PLAYDEN_STEAM_BENCHMARK_OUTPUT="${2:a}"
export PLAYDEN_STEAM_BENCHMARK_ITERATIONS="${3:-3}"
cd "$(dirname "$0")/.."
swift test -c release --package-path Packages/PlaydenKit --filter SteamInstallationBenchmarkTests.testInstallationFixtures
