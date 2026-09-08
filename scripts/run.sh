#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
built_app='DerivedData/Build/Products/Debug/Playden.app'
if [[ ! -d "$built_app" ]]; then
  ./scripts/build.sh
fi
# Never run from DerivedData: Xcode replaces/signs that bundle during builds and tests,
# which can invalidate Keychain access for the process that is still running from it.
# Keep the launch copy outside Documents/Desktop. Wine reads bundled Windows helpers at
# runtime; launching from a protected repository folder otherwise triggers a TCC prompt.
run_root="$HOME/Library/Application Support/Playden/Run"
mkdir -p "$run_root"
staging_root=$(mktemp -d "$run_root/.staging.XXXXXX")
trap 'rm -rf -- "$staging_root"' EXIT
ditto "$built_app" "$staging_root/Playden.app"
codesign --verify --deep --strict "$staging_root/Playden.app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$staging_root/Playden.app/Contents/Info.plist")

# Respect normal app quit handling. Never replace the running bundle or force-quit a game.
swift -e '
import AppKit
let bundleID = CommandLine.arguments[1]
let launchURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let apps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == bundleID || $0.bundleURL?.standardizedFileURL == launchURL
}
for app in apps { app.terminate() }
let deadline = Date().addingTimeInterval(10)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard apps.allSatisfy({ $0.isTerminated }) else {
    fputs("Playden is still running. Finish quitting it, then run this command again.\n", stderr)
    exit(1)
}
' "$bundle_id" "$run_root/Playden.app"
rm -rf -- "$run_root/Playden.app"
mv "$staging_root/Playden.app" "$run_root/Playden.app"
open "$run_root/Playden.app" --args "$@"
