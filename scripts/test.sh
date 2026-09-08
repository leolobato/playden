#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
swift test --package-path Packages/SteamKit
swift test --package-path Packages/PlaydenKit
xcodegen generate
signing_identity=$(python3 scripts/signing-identity.py)
xcodebuild -project Playden.xcodeproj -scheme Playden -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$signing_identity" test "$@"
