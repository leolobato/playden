# Steam preparation settings preservation — 8 September 2026

The interface repair is already on GameNative-macos main as `9ce9f16` and in the active
sibling checkout as `13312ff`. Its live Oniken repair and subsequent startup regression result are
documented in [the interface validation](2026-09-08-steam-interfaces.md).

A follow-up audit found that SteamPreparer rewrote all three generated `configs.*.ini`
files, and Big Screen separately replaced `configs.main.ini` with its offline policy.
The previous live repair preserved those files because they already contained the generated
defaults; custom options could still be lost on a later preparation or repair.

SteamCore now merges generated keys, preserving unrelated sections, options, comments,
line endings and UTF-8 BOMs. Repeated identical writes leave file contents and modification
time unchanged. Invalid UTF-8 and symlink destinations are rejected without replacing them.
Generated identity and save locations still refresh; obsolete tickets are removed. Owned-DLC
and Windows Cloud directory sections remain authoritative so stale entries are removed.
Big Screen applies its offline/networking settings using the same merge operation.

Dependency commits: `dd1b307` in the active `investigation/ios-runtime` checkout and `c9f6c22`
on main. Main was updated and tested in a disposable isolated checkout. Existing sibling
documentation/iOS changes and the supplied interface-fix worktree were preserved.

Validation:

- Active sibling: 71 tests, 2 existing skips, no failures.
  `/tmp/bigscreen-settings-steamcore-tests.log`.
- Main: 23 tests, 1 existing skip, no failures.
  `/tmp/bigscreen-settings-main-tests.log`.
- Big Screen: 241 package XCTest tests, 6 existing integration skips, 5 Swift Testing tests,
  and all 102 app tests passed. `/tmp/bigscreen-settings-all-tests.log`.
- Signed build passed and the app was staged/launched from its stable Application Support
  bundle after confirming no unfinished game sessions or Cloud claims. Build and launch logs:
  `/tmp/bigscreen-settings-build.log`, `/tmp/bigscreen-settings-run.log`.
- New tests exercise duplicate sections/keys, comments, CRLF, BOMs, unterminated final lines,
  path/name delimiters, obsolete generated values, invalid encodings and symlinks. Actual
  SteamPreparer and SteamInstaller retry/repair fixtures verify retained custom settings,
  original DLL bytes and save bytes, plus staging validation.
- SwiftPM initially reused a dependency build manifest that omitted the new source file.
  Regenerating it with `--disable-build-manifest-caching` resolved the build error; the normal
  full test script subsequently passed.

A read-only check of the live Oniken installation still finds 17 interfaces in
`~/Games/GameNative/gn-steam-252010/game/DATA/steam_settings/steam_interfaces.txt`, including
`STEAMUSERSTATS_INTERFACE_VERSION011`. This follow-up did not prepare or launch any live game.
At this checkpoint the Store User Data crash trigger was still unknown. The later user-clarified
startup replay passed; see [the updated interface validation](2026-09-08-steam-interfaces.md).
