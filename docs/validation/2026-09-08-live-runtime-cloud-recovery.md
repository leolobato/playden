# Live runtime recreation and Cloud restore — 8 September 2026

Validated the actual A Short Hike installation with Big Screen `b478589` and its local
SteamCore dependency `608a619`. This covers the keyboard-driven missing-runtime journey;
the physical controller acceptance gate remains open.

## Procedure and result

1. Confirmed the launcher had no unfinished sessions, active Cloud claims or running jobs.
   A process-identity check found no Wine processes belonging to this game's runtime and
   no unreadable Wine processes. Quit the launcher normally.
2. Backed up Catalog and recorded the installation, ownership markers, save and hashes of
   all 240 regular game files. Moved the entire owned CrossOver bottle intact into a private
   diagnostics backup. The original bottle and its save remain retained there.
3. Relaunched the staged, signed app and selected A Short Hike → Play using keyboard input.
   Big Screen recreated the missing runtime, completed source preparation, restored the Cloud
   save and launched the game. The recreated marker reports `ready: true` and
   `sourcePreparationPending: false`. The runtime has a different filesystem identity, while
   the installation ID and nonempty ownership token are unchanged.
4. Before gameplay, the restored 29,453-byte save matched the original exactly. Selected
   Continue in the real game and visually confirmed the restored world and 15 feathers.
5. Used the game's Save and Quit, then Quit from its title menu. Session
   `2A437FF6-15D1-44AC-9E71-E00F5A526201` ended cleanly with 611 seconds recorded.
   Automatic post-exit Cloud operation `4C65D3EA-DE72-4F6D-ADD9-32AFC660B5EE` completed,
   advancing the baseline from revision 3 to revision 4.
6. With no unfinished sessions or Cloud claims, ran the signed app's explicit, read-only
   `--cloud-read-check 1055540` probe over a fresh Steam connection. Its downloaded save
   matched the local post-gameplay file byte for byte; revision 4 stayed unchanged during
   the check. The process-identity check again found no owned or unreadable Wine processes.
7. Rehashed the game directory: all 240 regular files remain unchanged, with no additions
   or removals. This includes existing originals and app-specific source configuration.
   The save inside the retained original bottle still matches its pre-test hash.

Save SHA-256 values:

- Original and restored before gameplay:
  `2f3ca8e01136707fc5550f652bf83aba777ba51cb628b896e1a262dc969d4e7f`.
- Saved after gameplay and independently downloaded from revision 4:
  `2f605ed8620e2c8b0d4d3fdf9d40f38abe2a4b3594f0a75a2ac0d754382be591`.

Private evidence is under `.build/runtime-recovery-live/`: `recovery.json` identifies the
retained backup, with before/after Catalog records, hashes, save copies, the remote read report
and actual window captures. `restored-world-ready.png` and `pause.png` show restored progress;
the earlier `restored-world.png` was captured during loading and is not gameplay evidence.
Raw saves and account-scoped records are intentionally not committed.

## Remaining acceptance

Synthetic global Shift–Home input did not produce an observable exit overlay during this
session, including a second attempt with held modifier/key events. The game stayed running
and was closed through its own menus. This does not establish whether physical Shift–Home
fails. A subsequent [System Events check](2026-09-08-failure-retry-controls.md) opened the current
build's overlay, exercised Return, and stopped the game through Quit. The discrepancy is specific
to bare CGEvent injection; physical DS4 and game focus handoff acceptance remain open.

This test does not establish physical DS4/TV operation, unplug/reconnect, interrupted upload,
concurrent remote edits, account switching or the complete uninstall/reinstall journey.
The recreated runtime is left installed and usable; do not replace it with the retained old
bottle, since the current runtime contains the newly synchronized save.
