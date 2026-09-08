# Preferred game audio and visible quit actions — 8 September 2026

Settings → Audio now lists connected Core Audio output devices and System default.
Selection is stored by stable UID, with the display name retained for disconnected
status. The picker refreshes while open, preserves focus by UID, and keeps the
selection across disconnect/reconnect. It applies on the next game launch.

The launcher passes the preferred UID through its reserved launch environment to
the bundled Windows helper. Game/source launch metadata cannot override that key.
Audio-only helper requests are supported when no display geometry is available.
The helper initializes MMDevAPI to refresh Wine's device map, resolves the Core Audio
UID to an active Windows endpoint, and writes the per-bottle DefaultOutput before
creating the game process. It never sets the Mac's default output. System default
and unavailable-device paths clear Big Screen's own prior override. A later manual
Wine output override is preserved. Input/microphone selection is unchanged.

This uses Wine's existing configuration mechanism, verified against the installed
CrossOver runtime. Upstream references:

- [MMDevAPI device mapping and default endpoint selection](https://github.com/wine-mirror/wine/blob/master/dlls/mmdevapi/devenum.c).
- [Core Audio endpoint UIDs](https://github.com/wine-mirror/wine/blob/master/dlls/winecoreaudio.drv/coreaudio.c).

The live read-only Core Audio enumerator found ASUS VC239, LG Ultra HD, CalDigit
Thunderbolt 3 Audio and MacBook Pro Speakers. The opt-in `scripts/test-game-audio.py`
ran in idle Oniken's owned bottle, without opening a game/window or playing sound.
Its real child MMDevAPI query confirmed selection of MacBook Pro Speakers, fallback
for a nonexistent UID, and restoration of the original default. The test removed
its owned override; existing game saves and the running A Short Hike session were
not changed. Physical playback and Bluetooth unplug/reconnect remain live acceptance
checks, and games that explicitly select an endpoint can override the default.

Quit game is now visible in the top bar, the running game's detail actions and its
More menu. Keyboard/controller navigation reaches the same confirmation overlay;
its default action returns to the game. Confirmation retains the existing request
to close gracefully, followed by force after ten seconds, and the displayed warning.

Quit Big Screen is available as a top-bar power button and a Settings left-menu
action directly below About. Audio appears directly below Display.
These use the existing lifecycle: active sessions require confirmation; otherwise
normal shutdown pauses downloads and flushes state. Confirmation is bound to the
current session, cannot be reused, and does not bypass save synchronization.

Validation: all 151 app interaction tests passed before the final render check;
100 Runner/Catalog tests passed (three existing skips), plus the new focused runner
test verifies UID transport, audio-only requests, System default helper use and
rejection of source-provided audio overrides. The existing native placement/argument
suite also passes with the extended helper. Render tests cover the audio picker,
Settings left-menu quit action and running-game quit action at 1080p; full overlay consequence
renders retain 1080p/4K coverage. See the test logs under `/tmp/bigscreen-audio-*` and
ignored `.build/wine-monitor-investigation/` for runtime evidence.

The final offscreen AppKit render/OCR check passed for all three new screens; the
images were visually reviewed. ImageRenderer alone omitted AppKit-backed scroll
views, so this test uses a non-visible hosting window and captures its actual view.
The signed Release build passed and `codesign --verify --deep --strict` succeeded.
Bundle: `DerivedData/Build/Products/Release/Big Screen.app`. It has not replaced the
running `/Applications/Big Screen.app`.
