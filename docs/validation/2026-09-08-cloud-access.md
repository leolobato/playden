# Cloud folder and writer access — 8 September 2026

`CloudSaveAccess` supplies the production root callback for the Cloud coordinator. It checks the
current installation and exact active claim, resolves the game via `InstallStorage.directory`
and the bottle via `GameBottleManaging.ownedDirectory`, then inspects the owned bottle's processes.
It never prepares/removes a bottle or terminates a process. The existing descriptor-based save
store still checks every subsequent path component without following links.

Live game/launcher processes prevent access. Previously tracked writers omitted by inspection
are checked by PID plus birth identity; a known unreadable writer also prevents access. Idle
Wine services and unrelated unreadable macOS processes do not prevent sync. Reused PIDs do not
imply the old writer is alive. The claim/session reservation is checked again after asynchronous
folder lookup. A pre-launch or verified-exit session is accepted only as that claim's owner.

Catalog's latest runtime-session query ignores newer reservations that have not launched a
process, retaining the prior writer identities and crash/forced outcome for validation.

Six tests cover ownership/inspection failures, missing/stale claims, writer/service distinctions,
omitted writers and PID reuse, the exited session reservation, and a claim changed during folder
resolution. Catalog is real; root and process adapters are injected fixtures. Existing storage
and bottle tests cover their concrete ownership implementations. No live Cloud writes were made.

Logs: `/tmp/bigscreen-cloud-access-tests.log`, `/tmp/bigscreen-cloud-access-all-tests.log`.
Full regression passed: 156 package XCTest tests (3 existing integration skips), 5 Swift Testing
tests and 55 app tests, no failures.

## Next: acceptance-title validation

The private A Short Hike gameplay save is 9,641 bytes and begins with a .NET binary serialization
header; its root class is `GlobalData+GameData`. Its downloaded Cloud counterpart is 29,454 bytes.
These are binary files, not JSON. A read-only structural validator should check the entire record
stream and referenced save graph without loading assemblies or instantiating serialized classes.
The format reference is Microsoft's [MS-NRBF specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-nrbf/5acd9dc4-1439-433a-8d53-eb2922a142d8),
including [typed class records](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-nrbf/847b0b6a-86af-4203-8ed0-f84345f845b9),
[array records](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-nrbf/9c62c928-db4e-43ca-aeba-146256ef67c2)
and [member type information](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-nrbf/aa509b5a-620a-4592-a5d8-7e9613e0a03e).
This validator and app UI/factory wiring remain before live Cloud uploads are enabled.

A disposable read-only prototype at `/tmp/bigscreen-nrbf-inspect.py` successfully walked both
preserved files to their final MessageEnd record with no trailing bytes or unresolved object
references. The local file contains 61 objects; the Cloud copy contains 966. Both root objects
have `fileName`, `tags`, `inventory`, `playerReplayData` and `allCollectedNames`. Observed record
types: ClassWithId, SystemClassWithMembersAndTypes, ClassWithMembersAndTypes, BinaryObjectString,
BinaryArray, MemberReference, BinaryLibrary and ArraySingleString. This is format evidence for
the native validator, not a production upload-validation implementation. Neither copy was modified.
