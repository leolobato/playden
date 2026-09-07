#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project BigScreen.xcodeproj -scheme BigScreen -configuration Debug -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- build "$@"
codesign --verify --deep --strict 'DerivedData/Build/Products/Debug/Big Screen.app'
