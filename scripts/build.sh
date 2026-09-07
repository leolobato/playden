#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
xcodegen generate
signing_identity=$(python3 scripts/signing-identity.py)
xcodebuild -project BigScreen.xcodeproj -scheme BigScreen -configuration Debug -derivedDataPath DerivedData CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$signing_identity" build "$@"
codesign --verify --deep --strict 'DerivedData/Build/Products/Debug/Big Screen.app'
