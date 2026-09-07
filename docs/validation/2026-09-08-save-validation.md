# A Short Hike save validation — 8 September 2026

`ShortHikeSaveValidator` is a native Swift reader for the acceptance title's binary save graph.
It does not use BinaryFormatter, load assemblies or instantiate serialized classes. It reads the
entire stream, checks its header/end boundary, object/library/metadata references, unique IDs,
declared string/array/object types, finite numeric values, collection sizes and expected root
save objects/filename. Input, string, member, graph, record and nesting limits bound resource use.
Unsupported structures fail validation and keep the staged/local/remote copies available.

The reader follows Microsoft's [MS-NRBF format](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-nrbf/5acd9dc4-1439-433a-8d53-eb2922a142d8).
Named class arrays can appear in SystemClass/Class member metadata, which the real saves
exercise through dictionary entries and the inventory's Fish array. Validation reads values as
data and checks structure; it does not prove that every gameplay value is semantically correct.

`SteamSaveValidation` checks the immutable upload's size/hash and applies this structural check
to A Short Hike even after a clean exit. Other formats require a verified clean exit from this
owned installation; unknown, interrupted, crashed or forced writers remain pending until a
normal play/quit or a future title validator. The caller must use Catalog's latest runtime-session
query so a new pre-launch reservation does not hide the prior writer. A verified exited runtime
can establish clean exit before the session's post-Cloud final checkpoint.

Remote deletions require a clean exit, including mixed batches that upload one file and delete
another. The Cloud coordinator's mandatory validation callback now receives both upload payloads
and deletion names. This prevents an empty or partial upload array from bypassing deletion checks.
None of these checks changes account/conflict consent or advances a sync baseline.

## Validation

Seven tests cover:

- Complete graphs after absent, crash and forced-exit receipts.
- Every truncated prefix of the constructed fixture and trailing data.
- Missing references, duplicate IDs, wrong root identity/filename and declared type mismatches.
- Invalid collection lengths, excessive/negative array counts, booleans, NaNs and length encodings.
- Unknown formats, owned clean exit, changed installation identity and mixed/deletion-only batches.
- Changed staging bytes and structurally invalid saves despite clean exit.
- Both private preserved A Short Hike files, read-only, with additional truncated variants.

The real local save is 9,641 bytes; the downloaded Cloud copy is 29,454 bytes. Both passed the
native validator and the production upload-validation policy using a forced-exit test receipt.
No live saves or Cloud files were modified. Private fixtures are deliberately not committed.
Provide `BIGSCREEN_SHORT_HIKE_LOCAL_SAVE` and `BIGSCREEN_SHORT_HIKE_CLOUD_SAVE` to run that test;
otherwise it reports an integration skip.

Logs: `/tmp/bigscreen-save-validation-tests.log`, `/tmp/bigscreen-save-validation-all-tests.log`.
Full regression passed with the private-copy test enabled: 163 package XCTest tests (3 existing
integration skips), 5 Swift Testing tests and 55 app tests, no failures.

## Remaining

The live app still needs the Cloud factory/observer and controller-accessible status, conflict,
retry and offline controls. Real Steam upload, reinstall restoration and concurrent remote-edit
acceptance are outstanding. Structural validation of preserved bytes is not a live sync roundtrip.
