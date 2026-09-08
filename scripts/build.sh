#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
configuration=Debug
configuration_args=()
case "${1:-}" in
  --release)
    configuration=Release
    # CrossOver and the bundled Homebrew libraries target Apple Silicon.
    configuration_args=(ARCHS=arm64)
    shift
    ;;
  --help|-h)
    cat <<'EOF'
Usage: ./scripts/build.sh [--release] [xcodebuild arguments...]

Builds Debug by default. Use --release for an optimized app you can copy to
/Applications. Build output: DerivedData/Build/Products/<configuration>/Playden.app
EOF
    exit 0
    ;;
esac
derived_data="${PLAYDEN_DERIVED_DATA_PATH:-DerivedData}"
derived_data="${derived_data:A}"
xcodegen generate
signing_identity=$(python3 scripts/signing-identity.py "$configuration" "$derived_data")
xcodebuild -project Playden.xcodeproj -scheme Playden -configuration "$configuration" -derivedDataPath "$derived_data" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$signing_identity" "${configuration_args[@]}" build "$@"
built_app="$derived_data/Build/Products/$configuration/Playden.app"
codesign --verify --deep --strict "$built_app"
printf '\nVerified %s build: %s\n' "$configuration" "$built_app"
if [[ "$configuration" == Release ]]; then
  printf 'Quit Playden, then copy this app to /Applications and open it there.\n'
fi
