#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
swift test --package-path Packages/BigScreenKit
xcodegen generate
xcodebuild -project BigScreen.xcodeproj -scheme BigScreen -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- test "$@"
