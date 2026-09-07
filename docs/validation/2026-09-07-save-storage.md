# Save storage foundation — 7 September 2026

Implemented source-provided save mappings and a local snapshot/restore store. This is groundwork
for Keep saves and Steam Cloud; neither uninstall integration nor network synchronization is
complete yet.

Steam mappings preserve separate local paths and Cloud upload prefixes, including root overrides
and added local subfolders. The Android reference is
`../GameNative-android/app/src/main/java/app/gamenative/service/SteamAutoCloud.kt`
(repository HEAD `d8535825` when inspected). It also establishes the reference flow for later Cloud
work: change lists, SHA-1 file identities, upload batches, file commits and batch completion.
No Android account data or credentials were accessed.

A Short Hike's cached installed UFS metadata specifies
`WinAppDataLocalLow/adamgryu/A Short Hike/*.mountain`, non-recursive. The mapping points into the
owned CrossOver profile. GBE's separately configured `Steam/userdata/0` is retained locally and
is not presented as a proven remote mapping. Unresolved account substitutions and unsupported
roots stay explicit. Metadata alone cannot authorize deletion of unmapped files; no title is
marked as a verified save-retention recipe by this change.

SaveStore opens physical directories with descriptor-relative, no-follow traversal. It rejects
links, hardlinks and special files; streams SHA-256 and Steam-compatible SHA-1 hashes; checks for
files changing during backup; verifies the copied bytes; and publishes a versioned manifest only
after successful copying. Files are private (0600), folders 0700. Failed unpublished copies are
cleaned up when possible; crash leftovers are never considered usable backups. Callers must claim
the game session/maintenance lock and verify root ownership before using the store.

Restore verifies the entire archive and preflights every destination before writing. Different
existing content remains a conflict even if its timestamp is older. Identical files allow safe
retry after partial restore; no existing file is overwritten and retained archives are not consumed.

Evidence: 5 SaveStore tests cover two-root backup/restore, restart/idempotence, filters/recursion,
conflict preflight, corrupt archives, unpublished copies, source/destination symlinks, hardlinks,
traversal, empty saves and overlapping mappings. 3 source tests cover the A Short Hike metadata,
root overrides and unsupported mappings. Package suite: 90 XCTest passes, 3 existing skips, plus
5 Swift Testing passes (`/tmp/bigscreen-saves-runtime-tests.log`, package phase).

Still required: owned-root wiring, maintenance claims, recoverable uninstall/reinstall, conservative
retention of unknown layouts, Cloud account journals and transfers, and a real gameplay/save/load
roundtrip. Tests with `.mountain` fixtures do not establish actual A Short Hike save compatibility.
