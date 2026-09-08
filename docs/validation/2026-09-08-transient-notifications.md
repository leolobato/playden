# Transient notifications — 8 September 2026

FR-OVL-3 now has real install-queue and controller event wiring. Previously the unused `toast`
string never produced a view, and controller disconnection used a separate bottom-left banner.

The new informational cards follow the designer guidance: bottom-right, 560 canvas pixels wide,
18/22 padding, dark panel, 12-pixel status dot, Barlow Condensed 24 title and Barlow 18 detail.
They animate upward over 200 ms; reduced motion removes the transition. Download completion,
installation failure, verification/removal outcomes and controller connection use this component.
Failure cards point to Downloads, where Retry and View logs remain after the card disappears.
No toast is a focus target or changes the current screen, selection, modal or app activation.

The initial queue snapshot establishes a baseline without replaying historical results.
Repeated snapshots do not repeat an outcome; retrying a job can produce a new outcome. Up to
eight notices wait in memory, replacing older notices for the same job/controller. They wait
while the launcher is inactive, a game is active, a modal/setup/sign-in screen is open, or a
durable error takes priority. The visible card dismisses after five seconds. A visibility change
cancels that timer; a stale task cannot dismiss another card. A controller-disconnect card
persists until reconnection without changing focus. Low battery remains v2.

Validation:

- All 128 app tests passed; `/tmp/bigscreen-notifications-final-tests.log`.
- The queue-stream interaction test verifies a real observed failure, repeat suppression,
  retained Download recovery actions after dismissal, and a later successful retry outcome.
- Model checks cover restored history, replacement identity, hidden notices, and controller
  disconnect/reconnect without navigation changes.
- An actual `NSHostingView` test holds a toast behind a modal for more than five seconds, then
  verifies automatic dismissal after five visible seconds. It uses the production view task.
- Eight native snapshots completed: all four specified toast states at 1920×1080 with normal
  motion and 3840×2160 with reduced motion. The installation failure at 1080p and controller
  disconnect at 4K were visually inspected; cards fit above the footer/download indicator.
  Private captures: `.build/notifications-1080/` and `.build/notifications-4k/`.

These fixtures do not claim a new physical DS4 unplug/replug or live network interruption test.
Those remain in the full v1 acceptance matrix.
