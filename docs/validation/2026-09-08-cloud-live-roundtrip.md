# A Short Hike live Cloud roundtrip — 8 September 2026

Validated the signed production app against the existing Steam account and A Short Hike (1055540),
using its real installation and owned CrossOver bottle. No preview fixtures, direct database writes,
or manual edits to game save contents were used to perform synchronization.

## Read, conflict and restore

An independent read-only Cloud check downloaded the existing revision 1 save: 29,454 bytes,
SHA-256 `f332079e47bbf234ae588eb737140d6e40c0c57ffc16ef845367a54a62d22ae9`.
Report: `~/Library/Application Support/Big Screen/Diagnostics/cloud-read-04DA6383-525F-474B-B71C-F8AAE464A2C1/`.
The earlier local gameplay test save was different. Preserved all four existing local save-folder
files in `.build/cloud-live-validation/before-local/` before proceeding.

Opened Library → A Short Hike → Cloud saves → Retry sync using keyboard navigation. The real
coordinator staged both copies and presented conflict review with the correct dates and sizes.
The dialog initially focused Close. Selected **Use Cloud save** to retain the user's existing
remote progress, rather than upload the newer local test fixture. Operation
`8BFFE089-195B-425C-B5BC-58DA3AD09E58` completed, and the live local save matched the downloaded
revision 1 bytes and hash exactly. Both conflict copies remain in the managed SaveStore.

## Game launch, save and upload

Launched through Big Screen's Play action. Preflight operation
`41D10AB4-4F64-496E-BA20-4F91E5420D15` completed before the owned runtime started.
Selected Continue in the game and reached the restored world with the existing collected feathers
and inventory. Capture: `.build/cloud-live-validation/restored-gameplay.png`.

Used the game's **Save and Quit**, then Quit from its title menu. Session
`2D6BA1F1-9BB0-4AC1-B1CE-09EB43BF957D` recorded a clean exit. The game wrote a 29,453-byte save,
SHA-256 `60f7ad371c1b8057600e29315c6963bbdfac0234387b85250eeca1696cc19e6a`.
Post-exit operation `A4D2520B-28DA-4EDA-BB76-AB69A5F69887` recorded an upload decision, a durable
batch receipt for revision 2 and completed after verification. Big Screen returned to its details
page with Play focused and **Cloud saves · Up to date** visible.
Capture: `.build/cloud-live-validation/post-exit-up-to-date.png`.

Restarted into the independent read-only probe, establishing a fresh Steam connection. Remote
revision 2 contained one present file, no deleted/forgotten files, and its downloaded bytes matched
the game's newly written save exactly. Report:
`~/Library/Application Support/Big Screen/Diagnostics/cloud-read-58FD1AC4-B671-4E06-A6CF-A16CA800D3DA/`.
This verifies a real download/conflict/restore/play/save/upload/readback roundtrip, including the
upload adapter's batch revision handling. Returned to the normal signed app afterward; no game
session remains active.

## Remaining acceptance

This does not prove uninstall/reinstall restoration, real disconnected-network behavior, another
account, concurrent edits from another Steam client, interrupted live upload recovery, or other
games' save formats. Those remain required v1 work. Existing automated tests cover simulated
failure/recovery/account cases; this live run adds the successful production path only.
