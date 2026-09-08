# A Short Hike uninstall/reinstall Cloud restore — 8 September 2026

Validated the signed production app at `839fc30` with A Short Hike (1055540), through normal
keyboard-accessible UI. No direct catalog writes or manual save restoration were used.

Before removal, verified ownership and preserved private APFS copies of the game's owned container
and CrossOver bottle, including original DLLs and saves. Evidence is ignored under
`.build/uninstall-live-validation/`; these test backups are not an uninstall retention feature.

## Removal and remote preservation

The real confirmation initially focused Cancel and described the game files, runtime and local
saves to remove. Confirming ran a fresh Cloud check. Removal job
`AFD17C62-E776-433C-A61A-29AC4FB345DA` completed without unsynced-discard consent: both owned
directories were absent, the installation record was removed, and Downloads displayed Uninstalled.

An independent fresh-connection Steam read after removal confirmed revision 2 still contained the
same 29,453-byte save, SHA-256
`60f7ad371c1b8057600e29315c6963bbdfac0234387b85250eeca1696cc19e6a`.
Report: `~/Library/Application Support/Big Screen/Diagnostics/cloud-read-0C38328D-F16C-44C8-AB20-0D45C6166DCE/`.
Aggelos and Oniken were not modified by this test.

## Fresh installation and restored gameplay

Confirmed Install through the app. Job `47EA95A6-93AA-4CBA-8D99-432975427DF0` completed all stages.
It honored the existing games-volume preference, `/Volumes/VM/GameNative/games`, creating a new
installation identity and ownership token. The old installation had been under `~/Games/GameNative`.
The app correctly displayed Cloud saves as Not checked for the new installation.

Selected Play. Pre-launch Cloud operation `D324B30F-7A94-4C10-AF8B-0FF060A8C393` completed and
restored the save into the fresh CrossOver bottle. Before loading gameplay, its bytes and SHA-256
matched the independently verified remote save exactly. Continue loaded the saved world with its
collected feathers and inventory; capture: `.build/uninstall-live-validation/restored-gameplay.png`.

Used the game's Save and Quit, then Quit from its title menu. Session
`D88E5631-2264-40CC-B650-ACAD982406F4` ended with exit code 0 and `forced == false`.
Post-exit Cloud operation `CF664C89-B431-4CD2-8A72-AE0BA32D2985` completed.
A Short Hike remains installed on the selected volume with the restored progress; no test game
session remains active. Private evidence includes before/after installation records, removal job,
remote read report, restored save bytes, final session and Cloud operation.

This verifies successful live removal, remote-save preservation, reinstall and restore. It does
not establish physical drive-disconnection behavior, real network interruption, concurrent-client
edits, account switching or interrupted live upload recovery. Those acceptance items remain open.
