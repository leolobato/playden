# A Short Hike gameplay and local save reload — 7 September 2026

Used the real Big Screen-managed Windows installation of Steam app 1055540 with the current
CrossOver 26.2 template and offline GBE configuration. Before the test, the game's LocalLow folder
contained only Player.log and Player-prev.log; no existing local .mountain save was replaced.

Through the live app, launched A Short Hike, selected New game, completed its intro, moved the
character away from the cabin with arrow-key input and jumped with Z. Selected Save and quit in
the game's pause menu, then Quit from its title menu. Big Screen recorded a clean session end with
no failure. Save and quit returns to the title screen; it does not itself terminate the game process.

This produced a 9,641-byte file at:

`gn-steam-1055540/drive_c/users/crossover/AppData/LocalLow/adamgryu/A Short Hike/GameSaveNew.mountain`

The location matches the cached Steam UFS rule: WinAppDataLocalLow, `adamgryu/A Short Hike`,
`*.mountain`, non-recursive. A checksum-verified copy of the newly created test save is retained
under `.build/ashorthike-save-validation/`, with session IDs and SHA-256 evidence in `evidence.json`.
The format is not JSON; no deserialization of executable object data was attempted.

Launched again through Big Screen into a new process. The title screen offered Continue, which
loaded the character at the saved position beside the campfire instead of replaying the intro or
starting at the cabin door. Selected Save and quit and then Quit again. The second session also
ended cleanly without a launcher error. The live local save remains in place for the forthcoming
retention/reinstall test. No Cloud API or remote save was modified during this check.

Visual evidence: `.build/setup-ui/save-gameplay.png` and `.build/setup-ui/save-reloaded.png`.

This proves brief keyboard-controlled gameplay, creation of a local save and loading it in a new
game process. It does not prove physical DS4 gameplay, an Internet-disconnected launch, uninstall/
reinstall restoration, all configuration-file locations, or Steam Cloud synchronization. The save
mapping remains metadata coverage until the retention recipe and restore path are verified. A
future first Cloud sync must handle any different remote progress as a conflict, not automatically
upload this local test playthrough.
