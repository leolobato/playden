# Runtime settings — 7 September 2026

Selecting Settings → Library → Runtime previously reused the first-run setup page. Its headline
could say Ready while the progress card still showed the default Checking / 1 of 4 state, and it
showed onboarding instructions on a configured Mac.

Runtime now has a dedicated settings page. Opening it performs a read-only runtime inspection;
ready status, detected CrossOver version and required setup version come from that inspection.
Check again repeats the inspection, setup/retry appears when needed, and Back returns to the same
settings row. Actual preparation shows its current stage and Stop setup. Opening Runtime never
starts template preparation or marks onboarding complete. Missing/unready setup is labeled explicitly.

Validation:
- App suite: 52 tests passed (`/tmp/bigscreen-runtime-app-tests.log`), including ready → changed
  runtime → recheck → error → Back, no automatic preparation, retained settings focus and first-run
  regression coverage. Package tests separately passed: 95 passes, 3 existing skips.
- Signed build/deep verification passed (`/tmp/bigscreen-runtime-final-build.log`).
- Inspected native snapshots for ready/missing/progress at 1080p and 4K under
  `.build/runtime-settings-ui/`.
- Launched the stable unsandboxed Application Support bundle and opened Runtime by keyboard.
  The real Mac reported CrossOver 26.2 / Ready for Windows games; Check again and Back succeeded.
  Owned-window capture: `.build/setup-ui/runtime-settings-live.png`.

The dedicated settings view keeps the dark palette, large type, orange focus outline and spacing
used by the designer's settings reference. The onboarding wizard remains for actual first run.
