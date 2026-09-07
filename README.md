# GameNative Big Screen

A living-room launcher for Windows games on this Mac: a TV-sized interface, driven entirely by a
Bluetooth game controller, that browses your game libraries, installs games into CrossOver bottles
and plays them.

Status: product definition. The PRD lives in [`docs/prd/`](docs/prd/README.md); start there.

The [v1 implementation plan](docs/IMPLEMENTATION_PLAN.md) records proposed PRD corrections,
dependency work, delivery milestones and acceptance gates.

Related repositories (siblings under `../`):

- `GameNative-macos` — the Swift Steam layer (`SteamCore`) this app depends on, plus the VM runtime
  and its own desktop PRD (`docs/prd/`), which this PRD cross-references rather than repeats.
- `GameNative-android` — the upstream Android app whose per-game config schema informs v2 properties.
