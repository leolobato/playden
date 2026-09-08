# Game prerequisite preparation — 8 September 2026

New BioShock Infinite install plans pin recipe version 2 with the game's bundled x86 Visual C++
2008 SP1, Visual C++ 2010 SP1 and June 2010 DirectX installers. Version 1 plans retain their
recorded behavior. Unsupported recipe versions and missing prerequisite executables fail during
resolution; store metadata cannot introduce arbitrary setup commands.

The install queue runs prerequisites after creating the owned bottle and before executable
staging. Sources verifies the selected inputs against the pinned depot manifests, copies only
listed files into a private disposable directory, verifies the copies and passes literal arguments
to Runner. CrossOver commands are bounded, cancellable and captured by the existing diagnostic
journal. Original game files and saves are not modified by this preparation code.

Each successful step writes an atomic, synchronized completion record inside its owned bottle,
keyed by the recipe, command and pinned source payload. Failure leaves earlier completions intact.
Ownership and physical runtime identity are checked again before recording success. A recreated
bottle has no completions and installs the prerequisites again. Launch checks these records even
when the base runtime is already ready, so a previous prerequisite failure cannot be skipped by
Retry. Foreign or malformed completion records are preserved and rejected.
Already-completed steps skip folder traversal and copying; directory validation runs only when
an installer must execute.

## Validation

- Full regression suite: 232 package XCTest tests (6 opt-in integration skips), 5 Swift Testing
  tests and 87 app tests; no failures. `/tmp/bigscreen-prerequisites-all-tests.log`.
- Coverage includes a persisted queue restart at a failed prerequisite, successful-step reuse,
  launch retry after the base runtime becomes ready, source corruption, foreign runtime identity,
  runtime replacement during a command and legacy/unsupported recipe versions.
- Real CrossOver probe copied BioShock Infinite's existing prerequisites into a disposable folder
  and prepared a uniquely owned disposable bottle. All three installers exited successfully.
  Native `msvcr100.dll`, `d3dx9_43.dll` and `d3dx11_43.dll` replaced the initial runtime versions;
  the WinSxS directory also contained the VC90 CRT and `msvcr90.dll`.
- A fresh runtime-tool service then repeated preparation with the same completion records and
  executed zero additional commands. All 7 selected Runner tests passed, including the live probe.
  `/tmp/bigscreen-prerequisites-live-receipts.log` records component sizes and hashes.
- The probe removed its owned disposable bottle and working folder. It did not change the live
  BioShock Infinite installation, any user game bottle or saves.
- After limiting folder traversal to pending preparation, the targeted Sources installer suite
  passed. `/tmp/bigscreen-prerequisites-final-source-tests.log`.
- Signed app build passed and the updated bundle was staged/launched from its stable Application
  Support location after confirming no unfinished session or active Cloud claim. Logs:
  `/tmp/bigscreen-prerequisites-build.log` and `/tmp/bigscreen-prerequisites-run.log`.

This proves the bundled installer commands and completion/retry path. A complete fresh BioShock
Infinite installation and gameplay run, broader title recipes and missing-bottle Cloud/gameplay
acceptance remain open. The desktop was locked, so no new live UI/gameplay acceptance is claimed.
