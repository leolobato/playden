# Windows display helper

`PlaydenDisplay.exe` starts the selected executable in its existing CrossOver bottle, positions
its visible window on the preferred monitor during startup, and forwards its exit code. It uses
only Windows system DLLs. It does not change macOS display arrangement, ask for Accessibility
access, inject code, or edit game files. The helper only moves windows whose process ID matches
the child it created; retaining that process handle prevents PID reuse during observation.

The separate, opt-in [native primary display helper](../PrimaryDisplayHelper/README.md) can
temporarily change the macOS main display before this Windows helper launches. That setting
applies to the whole Mac and is off by default, including when Virtual desktop is enabled.

The Xcode post-build phase compiles `main.c` with Homebrew LLVM/LLD, then includes the result in the
signed app resources. No Windows SDK or C runtime is needed; `win32.h` declares the small x64 ABI
surface, with layout assertions. The helper also launches 32-bit games through CrossOver's WOW64
support. Set `PLAYDEN_LLVM_ROOT` / `PLAYDEN_LLD_ROOT` for other compiler installations.

The app sends a binary request on stdin through an unlinked temporary file descriptor. All fields
are little-endian: six int32 values (display x/y/width/height and primary width/height), uint32
argument count including the executable, then each argument as uint32 UTF-16 code-unit count and
UTF-16LE contents. Embedded nulls and excessive lengths are rejected. The helper constructs the
Windows command line with standard backslash/quote escaping. This avoids a `cxstart` quoting
failure for arguments containing spaces and a trailing backslash. The child's working directory,
DLL overrides and environment still come from the validated `LaunchSpec`.

The helper matches monitor rectangles after applying Wine's primary-display scale, so negative
coordinates and Retina scaling do not require guessing monitor enumeration order. If the display
vanishes before startup, it falls back to the Windows primary monitor. Games can choose another
monitor themselves after startup; automatic movement stops after ten seconds. Executables that
hand off their window to a different process and games that continually override window placement
need further coverage. Diagnostic output records whether the window reached the selected display.

The opt-in integration test compiles a tiny Windows argument fixture, checks Unicode / empty /
quoted / trailing-backslash arguments, exit-code propagation and missing-monitor fallback:

```sh
./scripts/test-display-helper.py --bottle '/path/to/an/idle/Playden-owned/bottle'
```

Run it only while that bottle has no game running. The fixture exits immediately and does not
modify an installation. The app's Swift tests cover binary request validation, literal wrapper
arguments, owned executable boundaries, and large stdin payloads without pipe backpressure.

References: [Microsoft command-line parsing](https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments),
[monitor positioning](https://learn.microsoft.com/en-us/windows/win32/gdi/positioning-objects-on-multiple-display-monitors),
and [SetWindowPos](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos).
