# Notification actions — 7 September 2026

Session notifications no longer intercept O / Options, which remains Sort & filter in Library.
The toast and footer show T / Triangle / Y for Notification actions. Pressing it focuses View logs;
arrows select View logs or Dismiss, Enter / Cross / A activates, and Escape / Circle / B returns
focus to the underlying screen. Its selection is preserved while its focus ring is suppressed.
Other panels retain their own input scope. Mouse actions remain available.

A Return to game warning is cleared after successful activation or game exit so it cannot claim
that an already closed game is still open.

Validation: two new interaction tests cover options routing, notification focus, opening logs,
dismissal, other-panel isolation and clearing obsolete activation warnings. `scripts/test.sh`
passed (134 passed, 3 existing skips across package and app tests). The native notification and
focused-notification snapshots were rendered at 1080p and 4K under `.build/notification-ui`.
