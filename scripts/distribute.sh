#!/bin/zsh
set -eu
set -o pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: ./scripts/distribute.sh VERSION BUILD_NUMBER

Build, Developer ID sign, and notarize Playden, then create a signed and
notarized drag-to-Applications DMG in dist/. Signing environment variable:
  PLAYDEN_DEVELOPER_ID       Developer ID Application certificate name or SHA-1

Notarization credentials (choose one):
  PLAYDEN_NOTARY_PROFILE     Existing notarytool Keychain profile name
  PLAYDEN_NOTARY_KEY_PATH    App Store Connect API private key (.p8) path
  PLAYDEN_NOTARY_KEY_ID      API key ID (required with KEY_PATH)
  PLAYDEN_NOTARY_ISSUER_ID   Issuer UUID (required for a team API key)

Example: ./scripts/distribute.sh 0.1 1
See docs/DEVELOPMENT.md for credential setup. Nothing is published to GitHub.
EOF
}
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  usage
  exit 0
fi
if (( $# != 2 )); then
  usage >&2
  exit 1
fi
version=$1
build_number=$2
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
  printf 'Use a numeric version (e.g. 0.1 or 0.1.0) and a positive integer build number.\n' >&2
  exit 1
fi
: "${PLAYDEN_DEVELOPER_ID:?Set PLAYDEN_DEVELOPER_ID to a Developer ID Application identity.}"
if [[ -n "${PLAYDEN_NOTARY_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$PLAYDEN_NOTARY_PROFILE")
elif [[ -n "${PLAYDEN_NOTARY_KEY_PATH:-}" ]]; then
  : "${PLAYDEN_NOTARY_KEY_ID:?Set PLAYDEN_NOTARY_KEY_ID for the API key.}"
  if [[ ! -f "$PLAYDEN_NOTARY_KEY_PATH" ]]; then
    printf 'Notarization API key file does not exist.\n' >&2
    exit 1
  fi
  notary_args=(--key "$PLAYDEN_NOTARY_KEY_PATH" --key-id "$PLAYDEN_NOTARY_KEY_ID")
  if [[ -n "${PLAYDEN_NOTARY_ISSUER_ID:-}" ]]; then
    notary_args+=(--issuer "$PLAYDEN_NOTARY_ISSUER_ID")
  fi
else
  printf 'Set PLAYDEN_NOTARY_PROFILE or PLAYDEN_NOTARY_KEY_PATH and PLAYDEN_NOTARY_KEY_ID.\n' >&2
  exit 1
fi

# Require a distribution identity, never the development/ad-hoc fallback.
signing_identity=$(python3 - <<'PY'
import os
import re
import subprocess
import sys

requested = os.environ["PLAYDEN_DEVELOPER_ID"]
result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                        check=True, capture_output=True, text=True)
identities = re.findall(r'\d+\) ([0-9A-F]{40}) "([^"]+)"', result.stdout)
matches = [digest for digest, name in identities
           if name.startswith("Developer ID Application:") and requested in (digest, name)]
if len(matches) != 1:
    sys.exit("Select one valid Developer ID Application identity from security find-identity -v -p codesigning.")
print(matches[0])
PY
)
# Validate stored credentials before spending time building; never read passwords into the shell.
xcrun notarytool history "${notary_args[@]}" --output-format json >/dev/null

export PLAYDEN_DERIVED_DATA_PATH="$PWD/.build/distribution/DerivedData"
PLAYDEN_CODE_SIGN_IDENTITY="$signing_identity" ./scripts/build.sh --release \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS=--timestamp MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number"

mkdir -p dist .build/distribution
staging_root=$(mktemp -d "$PWD/dist/.distribution.XXXXXX")
# zsh can bypass EXIT when errexit is triggered by a function returning failure.
trap 'rm -rf -- "$staging_root"' EXIT ZERR
log_root=$(mktemp -d "$PWD/.build/distribution/notarization.XXXXXX")
printf 'Notarization results and Apple logs: %s\n' "$log_root"
mkdir "$staging_root/payload"
app="$staging_root/payload/Playden.app"
ditto "$PLAYDEN_DERIVED_DATA_PATH/Build/Products/Release/Playden.app" "$app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")

# Sign nested native libraries before the app so hardened runtime library validation
# accepts them. Windows PE helpers are resources and remain unchanged.
for library in "$app"/Contents/Frameworks/*.dylib; do
  codesign --force --sign "$signing_identity" --timestamp --options runtime "$library"
done
codesign --force --sign "$signing_identity" --timestamp --options runtime "$app"
codesign --verify --deep --strict "$app"

notarize() {
  local artifact=$1 label=$2 staple_target=$3 result submission_id notarization_status submit_failed=false
  result="$log_root/$label-result.json"
  xcrun notarytool submit "$artifact" "${notary_args[@]}" \
    --wait --output-format json >"$result" || submit_failed=true
  if ! submission_id=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$result"); then
    printf 'Notarization returned no submission ID. Details: %s\n' "$result" >&2
    return 1
  fi
  notarization_status=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("status", "Unknown"))' "$result")
  xcrun notarytool log "$submission_id" "${notary_args[@]}" "$log_root/$label-log.json"
  if $submit_failed || [[ "$notarization_status" != Accepted ]]; then
    printf 'Notarization was %s. Review %s/%s-log.json\n' "$notarization_status" "$log_root" "$label" >&2
    return 1
  fi
  xcrun stapler staple "$staple_target"
  xcrun stapler validate "$staple_target"
}

# Notarize a ZIP, then staple the app before placing it in the read-only DMG.
ditto -c -k --keepParent "$app" "$staging_root/Playden.zip"
notarize "$staging_root/Playden.zip" app "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"

ln -s /Applications "$staging_root/payload/Applications"
dmg_name="Playden-$version-$build_number-arm64.dmg"
dmg="$staging_root/$dmg_name"
hdiutil create -volname 'Playden' -srcfolder "$staging_root/payload" -fs HFS+ -format UDZO "$dmg"
codesign --sign "$signing_identity" --timestamp --identifier "$bundle_id.dmg" "$dmg"
notarize "$dmg" dmg "$dmg"
codesign --verify --strict "$dmg"
hdiutil verify "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

# Only expose the final artifact after both submissions and all checks succeed.
mv -f "$dmg" "dist/$dmg_name"
printf '\nReady for distribution: %s/dist/%s\n' "$PWD" "$dmg_name"
