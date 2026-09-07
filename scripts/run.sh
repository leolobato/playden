#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
built_app='DerivedData/Build/Products/Debug/Big Screen.app'
if [[ ! -d "$built_app" ]]; then
  ./scripts/build.sh
fi
# Never run from DerivedData: Xcode replaces/signs that bundle during builds and tests,
# which can invalidate Keychain access for the process that is still running from it.
run_root="$PWD/.build/Run"
mkdir -p "$run_root"
staging_root=$(mktemp -d "$run_root/.staging.XXXXXX")
trap 'rm -rf -- "$staging_root"' EXIT
ditto "$built_app" "$staging_root/Big Screen.app"
codesign --verify --deep --strict "$staging_root/Big Screen.app"

# Respect normal app quit handling. Never replace the running bundle or force-quit a game.
swift -e '
import AppKit
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.gamenative.bigscreen")
for app in apps { app.terminate() }
let deadline = Date().addingTimeInterval(10)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard apps.allSatisfy({ $0.isTerminated }) else {
    fputs("Big Screen is still running. Finish quitting it, then run this command again.\n", stderr)
    exit(1)
}
'
rm -rf -- "$run_root/Big Screen.app"
mv "$staging_root/Big Screen.app" "$run_root/Big Screen.app"
open "$run_root/Big Screen.app" --args "$@"
