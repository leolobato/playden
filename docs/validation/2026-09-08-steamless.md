# SteamStub preparation — 8 September 2026

PRD 05 FR-INST-8 requires Steamless for SteamStub executables. Previously Sources detected a
`.bind` entry point and stopped preparation. It now runs pinned Steamless 3.1.0.5 through the
actual owned CrossOver bottle supplied by the install queue or missing-runtime session recovery.
Sources remains independent of Runner: Domain defines `RuntimeToolRunning`, App injects
`CrossOverTools`, and Runner verifies ownership and executes a finite, logged/cancellable command.

Original files are verified against pinned Steam manifests before preparation. Executables that
need unpacking receive `.orig` backups, the tool operates only on a disposable copy, and output
must parse as a PE of the same architecture with a mapped entry point outside `.bind`. The original
hash is rechecked before atomic output publication. Version 2 preparation receipts include the
executable's transformed SHA-256. DLL-only version 1 receipts remain supported. Unpacking also
works when the game has no Steam API DLL. Invalid output never replaces the installed executable.

Replay derives output from the retained original even after interruption before recording the
receipt. Verify/repair checks original manifest hashes separately from transformed hashes, repairs
the original backup path and repeats preparation. Save files are unaffected. Preparation version
metadata stays consistent when session recovery updates the installation under a Cloud reservation.

Validation:

- Full regression run: 223 package XCTest tests (5 integration skips), 5 Swift Testing tests,
  87 app tests passed. `/tmp/bigscreen-steamless-all-tests.log`.
- After the final staging-version consistency change, the complete package suite passed again:
  `/tmp/bigscreen-steamless-final-package-tests.log`. The Cloud reservation test now checks a
  version 2 preparation and rejects inconsistent version metadata.
- Sources fixtures cover unpacking with/without an API DLL, serialized receipt restoration,
  replay, damaged original repair, save preservation, invalid/still-packed output, and recovery
  after a failed pass before receipt persistence. Runtime tests cover literal arguments, rejecting
  unowned bottles without execution, tool failure, timeout and cancellation.
- Real CLI test: `BIGSCREEN_STEAMLESS_ORIGINAL` pointed to BioShock Infinite's retained original
  under `/Volumes/VM/GameNative/games/app_8870/`. A unique owned probe bottle was created, a temporary
  copy was unpacked, output PE validation passed, the original bytes compared equal, and the
  probe bottle was removed. All 12 Sources installer tests passed with this opt-in test enabled:
  `/tmp/bigscreen-steamless-live-test.log`. No live BioShock executable, configuration or save was
  modified; no game was launched by this test.
- The first real probe exposed Wine Mono resolving Steamless.API before the CLI installs its
  assembly resolver. Identical verified API/disassembler copies beside the temporary CLI fixed
  it. No upstream binaries were modified.
- Signed build passed: `/tmp/bigscreen-steamless-build.log`. Verified every Steamless resource
  inside the built app against its pinned inventory. `python3 scripts/vendor-steamless.py`
  reproduced all 16 pinned files and the resource manifest successfully.

This proves real executable unpacking and automated preparation/repair behavior. Full SteamStub
title installation and player-controlled gameplay remain acceptance tasks, as do title-specific
prerequisites. Upstream provenance and license are documented in [STEAMLESS.md](../STEAMLESS.md).
