#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
swift test --package-path Packages/SteamKit
swift test --package-path Packages/BigScreenKit
xcodegen generate
signing_identity=$(python3 scripts/signing-identity.py)
xcodebuild -project BigScreen.xcodeproj -scheme BigScreen -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$signing_identity" test "$@"
