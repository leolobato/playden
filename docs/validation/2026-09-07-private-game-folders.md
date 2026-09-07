# Private Windows folders and first real installation — 7 September 2026

Oniken (Steam app 252010) completed installation through the signed Big Screen app. Its saved job
reused the verified download, created the owned CrossOver bottle, staged the Steam API replacement,
validated originals and staged files, and atomically committed the installation. The job is
`completed/finished` and the catalog contains one real installation. Play supervision is still open;
this is installation evidence, not a claim that the game has been played successfully.

## Folder setup

The earlier live attempt stopped in CrossOver's clone restore hook, which opened a macOS Desktop
permission prompt. Keychain access was already working. CodeWeavers' published 26.2 source
(`sources/wine/dlls/shell32/shellpath.c`, `wine_update_symbolic_links`) confirms that restore updates
Windows shell links to native user folders. The source's XDG configuration support provides private
folder targets; `CX_DIRECT_DESKTOP` avoids the additional native Desktop link.

`BottleFolders` now configures these settings only after the launcher ownership receipt is verified.
Initial template creation also receives private bootstrap destinations before its first Wine process.
The finished template and each game keep folder targets inside `.bigscreen-folders`. Copying and
publishing a game rewrites the targets to the final bottle path before its restore/startup check.

Old shell symlinks are unlinked without following them. Physical directories and their contents are
kept. This includes Windows `Videos` (whose XDG destination is `Movies`) and the special native
Desktop links. Verification rejects personal-folder links and malformed/symlinked configuration.
A ready owned bottle with old mappings can be repaired through the same preparation method.
Before retrying a partial clone, scoped wineserver stop/wait prevents a detached old server from
continuing to use the prefix that is about to be removed.

## Evidence

- `./scripts/test.sh`: 58 package XCTest cases (3 optional probes skipped), 5 focus tests, and
  40 app tests: **100 passed, 3 skipped**, no failures.
- Three folder tests check that personal link targets and physical save files remain untouched,
  configuration is idempotent, publication rewrites destinations, and external links/configuration
  are rejected. The test includes the Windows Videos mapping found during the real folder audit.
- Real CrossOver 26.2 fresh-template creation/startup/delete: 5 tests passed, 17.47 seconds.
- Real owned-game clone/startup/delete plus folder tests: 7 passed, 14.60 seconds.
- Live signed-app Retry on Oniken resumed at bottle creation and completed installation without
  granting the Desktop prompt. Stored launch metadata is `Oniken.exe`, working directory `.`,
  argument `-steamwin`, and `steam_api=n,b`.
- A temporary maintenance harness compiled the current Runner sources and read Oniken's ownership
  receipt to run `CrossOverGameBottles.prepare`/`isReady`/`BottleFolders.verify` after the Videos fix.
  All six Windows user folders were then checked on disk: Desktop, Documents, Downloads, Pictures,
  Music and Videos exist and resolve inside `gn-steam-252010`.

Sources: [CodeWeavers source downloads](https://www.codeweavers.com/crossover/source),
[the exact 26.2 source archive](https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.2.0.tar.gz).
No CrossOver binaries or source are modified or redistributed by this change.

Remaining work includes the complete launch/session/controller/exit journey, Steamless and title
prerequisites, repair/uninstall/save retention, storage utilization and network speed/ETA, and the
remaining PRD acceptance gates. The first-run permission behavior was verified for this already
signed-in Mac; a clean user-profile first-run test is still required.
