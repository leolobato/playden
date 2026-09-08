# Steam install access and launch choices — 8 September 2026

The installed Release app reported expired authentication immediately after a successful
sign-in while resolving Armored Core VI (1888160). A signed, read-only diagnostic using the
same Keychain service confirmed that the saved token worked and Steam accepted CM logon.
The first failing request was the key for depot 1888162: Steam EResult 15 (AccessDenied).
This was a content entitlement error, not evidence of a Release signing or Keychain failure.

The previous selector considered OS, language and DLC app ownership, but ignored package
depot entitlements. For this account, 1888161 and 1888164 are authorized; 1888162 and 1888163
are not. Plans now select and retain the entitled subset, and downloads recheck access.
Content access denials no longer become an expired-sign-in prompt. Authentication-endpoint
renewal rejection still requires sign-in.

A second failure became visible after manifest retrieval: launch option 2 belongs to the
publisher's `dev-debug` branch, but the parser previously discarded `betakey`. Public
installs now exclude that option and the unowned artbook DLC option. The final Release probe
verified both authorized manifests and produced an install plan for 64,580,321,776 download
bytes with exit status 0. No game content chunks were downloaded and no game was launched.

Games with multiple eligible options now show a picker on Play. The per-game **Always use
this** choice persists in catalog edits and can be changed or cleared through **More → Launch
options**. A changed or removed remembered option prompts again. One-time selections survive
Cloud review and runtime preparation, without replacing the installation's prepared default.
Existing Steam installations can recover choices from their saved metadata offline.

Validation:

- BigScreenKit: 250 XCTest tests, 6 existing integration skips, no failures; 5 Swift Testing
  tests passed. Focused installer tests rerun after the final launch-only DLC round-trip case.
- App: 30 focused tests passed for install authentication, launch choices, persistence and
  session interactions. Picker preferences were verified across reopening the SQLite catalog.
- SteamKit: 3 PICS launch-parser tests passed, including branch/description persistence and
  decoding old launch records.
- Signed Release build and strict signature verification passed. Live probe used an isolated
  temporary copy outside Documents with the same signing identity and bundle identifier.
- Release picker snapshot reviewed at `.build/launch-options-review/launch-options.png`.
  Its launch choices are synthetic layout fixtures.

The running `/Applications/Big Screen.app` was not replaced. This verifies install resolution
and launch-choice handling; it does not establish Armored Core gameplay compatibility.
