# Runtime preparation acknowledgment — 8 September 2026

## Problem and behavior

A runtime clone could pass its base startup check before the source finished preparing and
validating the game. A source failure or app interruption at that point left a ready bottle.
The next launch could skip source staging because `GameRunner.prepare` only reported whether
the base runtime had just changed. Per-prerequisite receipts alone did not close this gap.

The owned bottle marker now keeps `sourcePreparationPending` until the validated source result
has been checkpointed. `GameRunner.prepare` continues to request source preparation after a
restart even when base runtime creation already succeeded. Sessions acknowledges completion only
after saving the staging receipt and launch specification in Catalog. Failure to save or acknowledge
cannot launch a game; the pending state remains retryable. CrossOverRunner also checks the pending
state at its launch boundary.

The install queue acknowledges after its source staging and launch validation are checkpointed,
before committing the installed record. Retry can repeat acknowledgment if the final commit fails.
When the runtime disappears between attempts, it invalidates runtime, prerequisite, staging and
launch-validation checkpoints, retaining the verified download. If it disappears during execution,
the job fails with a retry action and those checkpoints are invalidated for the next attempt.

Existing ownership markers without this field conservatively require one source validation on
the next launch. Completing preparation does not replace the bottle or touch its saves. A new or
reconfigured bottle always starts pending. Completion checks the existing ownership token and
runtime readiness, and uses the same atomic, synchronized ownership-marker write as bottle setup.

## Evidence

- Full package and app regression suite passed: 236 package XCTest tests (6 opt-in skips),
  5 Swift Testing tests and 87 app tests. `/tmp/bigscreen-preparation-ack-all-tests.log`.
- Session tests inject failures during staging, validation and acknowledgment, reopen Catalog
  and recreate SessionService/Runner, then verify preparation finishes before launch. Failed
  staging/validation retains the previous launch specification; an acknowledgment failure occurs
  after the validated specification is saved. A subsequent ordinary launch skips completed staging.
- Queue tests remove the fixture runtime after failures at prerequisites, staging, validation
  and acknowledgment. A reopened queue completes each case with one download and a rebuilt runtime.
- Real ownership-marker tests cover restart, rejected foreign ownership, direct-launch rejection,
  legacy-marker migration with unchanged save bytes and newly required preparation after recreation.
- A uniquely owned disposable CrossOver bottle passed clone/startup, pending-state inspection,
  acknowledgment, reopening/rechecking, repeated base preparation, scoped deletion and recreation
  with preparation required again, followed by cleanup. All 9
  selected GameBottle tests passed without skips. `/tmp/bigscreen-preparation-ack-live.log`.
- Signed app build passed and was staged/launched normally after confirming no unfinished session
  or active Cloud claim. `/tmp/bigscreen-preparation-ack-build.log` and
  `/tmp/bigscreen-preparation-ack-run.log`.

The disposable probe above did not remove or recreate any user game runtime. A subsequent
[live A Short Hike check](2026-09-08-live-runtime-cloud-recovery.md) verified missing-bottle →
Cloud restore → restored gameplay → clean quit → upload and independent remote readback,
using keyboard input and preserving the old bottle intact. Physical controller acceptance
remains open. Separately, recovery of an archived unsynced
upload after losing its runtime, before local publication begins, still needs focused validation;
this checkpoint does not establish that Cloud scenario.
