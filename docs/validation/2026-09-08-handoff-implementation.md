# Resumed handoff implementation — 8 September 2026

The user resumed the handoff and subsequently requested a percentage for the post-download
“Verifying files” state shown during Armored Core VI installation. The running `/Applications`
app and its jobs/saves were left in place. No game, controller events, window movement or app
replacement was used for this pass.

## Changes

- Quit game/launcher consequences remain visible even when a focus or shutdown error exists.
  Errors render separately and are limited to six lines so both actions and consequences fit.
  Full errors remain in diagnostics. Existing session-bound one-use approval behavior is retained.
- PS tap now emits Home on release; a one-second hold emits only Hold Home. Releasing a completed
  hold cannot emit a second Home action. Controller replacement discards an unfinished press.
- Fetch, image decode, bounded disk caching, coalescing and cancellation moved from App to the
  `Artwork` package target. Five loader tests now run without the app; three NSImage/fallback
  adapter tests remain app tests. The App memory/presentation adapter remains explicit in the audit.
- App test hosts use a prohibited activation policy and do not install controller/window/service
  wiring. Closing a fixture's final window no longer terminates the test runner. Production
  last-window/active-session behavior is unchanged.
- File verification now reports checked bytes across all selected depots. Final validation includes
  both retained originals and transformed files in its denominator. Progress is ephemeral, bounded
  by invocation/stage identity, monotonic, and hidden on pause; it never overwrites durable downloaded
  bytes. Missing/corrupt files remain invalid even when examination reaches 100%.
- Downloads, game details and the compact indicator use the verification percentage and checked-byte
  count. They do not reuse a completed download's 100% bar while waiting for verification samples,
  display network speed/ETA for disk checks, or round 99.x% up to 100%.
- Updated handoff/plan and added a 109-ID PRD inventory plus milestone/release evidence tables.
  Retained PRD/design indefinite launch waiting explicitly supersedes the proposed 60-second state.
  Generic focus tree/nearest geometry, full physical acceptance and compositor pacing remain open.

## Verification

`./scripts/test.sh` passed against the final implementation:

- SteamKit: 59 XCTest tests, 2 existing opt-in skips, no failures.
- BigScreenKit: 267 XCTest tests, 6 existing opt-in skips, no failures; 5 Swift Testing tests pass.
- App: 147 XCTest tests, no failures (five artwork tests moved into the package).
- Log: `/tmp/bigscreen-verification-percentage-tests.log`.
- xcresult: `DerivedData/Logs/Test/Test-BigScreen-2026.09.08_22-25-21-+0200.xcresult`.

New coverage checks aggregate verification across files/depots and transformed files, corruption
rejection, paused/stale-stage callbacks, unchanged downloaded counts, no premature 100%, PS tap/hold
exclusivity, and rendered percentage/consequence text. Six rendered images are attached to xcresult:
launcher quit warning, game exit warning, and verification at both 1920×1080 and 3840×2160 with
reduced motion. OCR asserts the consequences, actions, warning and actual verification percentage
remain visible. The 1080p quit and Downloads layouts were also visually inspected.

Exported images and their manifest are in `.build/verification-percentage-review/`.
These are isolated SwiftUI renders, not proof of AppKit foreground activation or physical input.
The verification capture uses fixed fixtures and shows “Verifying files 50%”, a half-filled bar,
and “1.75 GB of 3.5 GB checked”. No extra scan of the user's 65 GB installation was performed.

Two earlier test failures were investigated rather than counted as passes:

1. With no normal app window in the isolated test host, closing a notification-test window triggered
   last-window termination. xcresult reported exit code 0 during the next test. Opting only test hosts
   out of automatic last-window termination fixed it; the full app suite then passed.
2. A queue test timed out and immediately reported `Expected completed, got completed`. Its polling
   helper now uses a monotonic deadline and accepts the requested state from its final authoritative
   sample. Production queue behavior was unchanged. Subsequent full suites passed.

The private old `/tmp/bigscreen-launcher-quit-ui.swift` now guards a missing expected staged process;
`swiftc -typecheck` passed (`/tmp/bigscreen-handoff-helper-check.log`). Its old bundle/path selection
was deliberately not redirected at the user's running installation. Do not reuse it or runtime JSON
without fresh identity checks. Global shortcut acceptance still requires actual System Events input.

`./scripts/build.sh --release` passed, including strict/deep signature verification. Log:
`/tmp/bigscreen-handoff-release-build.log`. Reviewable bundle:
`DerivedData/Build/Products/Release/Big Screen.app`. It has not been copied over the running app.

## Remaining acceptance

This does not complete v1. The [requirement inventory](2026-09-08-v1-requirement-audit.md) records
remaining architecture/coverage work, full live quit/cancel/confirm/window-close/retry acceptance,
passive game focus, physical DS4/TV/display/volume behavior, measured cold/warm 600+ title compositor
pacing, network/auth/account-switch recovery, and a fresh complete BioShock Infinite gameplay run.
The new percentage is in the build output; the already-running installed app has not been replaced.
