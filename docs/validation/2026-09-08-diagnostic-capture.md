# Command capture and Cloud stage history — 8 September 2026

Finite CrossOver commands now report successful, failed, cancelled and timed-out results to the
owning job/session's diagnostic journal. Task-local scopes follow install workers, session launch,
recovery and termination, and do not leak between unrelated concurrent operations. Only the tool's
basename, result and redacted stdout/stderr are recorded; arguments and environments are excluded.
Command transcripts remain separate from process/failure snapshots, so a later checkpoint cannot
replace earlier setup output. Older diagnostic records decode without the new optional fields.

A diagnostic write failure preserves the tool's actual result and leaves a visible diagnostic
warning for the current app run. Subsequent successful writes do not claim that missing details
were recovered. Rotated-out logs are not resurrected by late command callbacks.

Process output buffering now retains recent complete lines after redaction, rather than removing
an arbitrary raw prefix. Oversized lines are omitted while the pipe continues to drain. Quoted
credential context spans chunks and newlines; incomplete quoted fields and JWT fragments are
redacted during polling. Both process output and the aggregate command transcript are bounded at
256 KiB each, with explicit omission notices. Redaction expressions are cached for output floods.

Session history records runtime preparation, pre-launch Cloud checks/results, explicit offline
choices and post-exit Cloud checks/results. Account identities, remote URLs and save contents are
not included in those events.

## Validation

- Full suite: 199 package XCTest tests (4 integration skips), 5 Swift Testing tests and 76 app
  tests passed. `/tmp/bigscreen-diagnostic-capture-all-tests.log`.
- Coverage includes concurrent command scopes, real stdout/stderr and exit codes, timeout/spawn
  failures, transcript retention, diagnostic-write failure, bounded output floods, oversized/split
  credentials, Unicode, multiline credentials, Cloud conflict/offline/retry and post-exit phases.
- Opt-in real CrossOver clone/startup/delete probe: all 7 GameBottleTests passed without skips.
  The unique disposable bottle was created, produced the successful `BIGSCREEN_GAME_BOTTLE_READY`
  command output through the scoped capture, and was removed. Existing game bottles were untouched.
  `/tmp/bigscreen-diagnostic-capture-crossover.log`.
- Signed build passed and command-transcript layouts were rendered and inspected at 1080p and 4K.
  `/tmp/bigscreen-diagnostic-capture-build.log`; `.build/diagnostic-capture-ui/` and
  `.build/diagnostic-capture-ui-4k/`. Changes after the full suite only extend the opt-in test and
  add a command transcript to the screenshot fixture.
- Live A Short Hike session `8BB726F7-7715-44D5-A1D4-F7ACCED2C8C9` used its existing ready bottle,
  reached the title menu and exited through Quit. Recorded outcome: clean, exit 0, not forced.
  The journal and materialized text log include `Cloud before launch · checking/upToDate` and
  `Cloud after exit · checking/upToDate`. The save hash remained unchanged. Private evidence is in
  `.build/diagnostic-capture-live/`.

## Still open

Settings reset and live Finder selection acceptance remain open. Before the missing-bottle live
test, investigate the Cloud baseline: runtime preparation can recreate a bottle while retaining
the same installation identity, and the three-way planner uses that installation identity to
accept the old baseline. An absent save in a replacement runtime must not silently become a
remote deletion. No existing bottle was removed/recreated in this checkpoint. The full v1 Cloud,
controller/TV and release acceptance matrix remains outstanding.
