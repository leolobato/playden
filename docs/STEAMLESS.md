# Steamless preparation dependency

Playden bundles the unmodified [Steamless v3.1.0.5 release by atom0s](https://github.com/atom0s/Steamless/releases/tag/v3.1.0.5).
It invokes the CLI for SteamStub executables downloaded through the authenticated, owned-depot
install path. A disposable input copy and the game's owned CrossOver bottle are used. The tool
does not launch the game. Original game bytes are retained and verified against pinned manifests.

- Upstream commit: `cd770bf9749d3e4f438d23ac643917ad1a804257`.
- Archive: `Steamless.v3.1.0.5.-.by.atom0s.zip`.
- Archive SHA-256: `e3e2d22e098ff3fb359b2876aa2bed9596f0501e6ff588cbffae90a76d2dc4f5`.
- Resource inventory SHA-256: `817b6edd5c8adaba777eb4d1a4f88ccbe01a5460bd3919260ba6327ebd6fbdef`.
- Upstream license: **CC BY-NC-ND 4.0**, preserved verbatim as `Resources/Steamless/LICENSE`.
  This is not a permissive software license; commercial redistribution requires a separate
  distribution decision. No upstream binaries or source are modified here.

`python3 scripts/vendor-steamless.py` reproduces the resources from the pinned release and source
license, rejecting unexpected hashes before writing. App builds use checked-in resources and do
not fetch a latest release. `SteamUnpacking` verifies the complete inventory before invocation.
Only Sources owns this dependency; Domain carries a source-neutral runtime-tool protocol and
Runner verifies bottle ownership and executes a finite command with cancellation and logs.

Invocation: `Steamless.CLI.exe --quiet <Windows input path>`. The CLI writes
`<input>.unpacked.exe`. CrossOver's Wine Mono requires `Steamless.API.dll` and `SharpDisasm.dll`
beside the CLI before its assembly resolver starts. Identical copies are placed there only in the
temporary working directory; bundled release contents stay unchanged. CrossOver's bundled Mono is
used, with no separate .NET installation or template prerequisite.

Preparation receipt version 2 extends version 1's DLL mutations with manifest-owned executable
mutations. Original backups use `.orig`; transformed SHA-256 hashes are checked separately from
Steam's original content hashes. Existing version 1 installations remain supported. Retry always
derives unpacked content from the verified original, including after interruption before the
receipt was stored. Repair downloads damaged originals to their backup paths and repeats staging.
