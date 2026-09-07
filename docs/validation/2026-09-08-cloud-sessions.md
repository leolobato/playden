# Cloud session integration — 8 September 2026

`SessionService` now accepts a `CloudSyncManaging` coordinator. It requests sync after owned bottle
preparation/restaging and before launching a process. A non-success result keeps the pre-launch
session reserved and publishes `awaitingCloud` with its status. Retry forwards the exact reviewed
authorization; Play offline is allowed only when the coordinator reports it safe and skips only
that pre-launch check. Cancelling a waiting launch finalizes the session without spawning a game.

After observed runtime exit, the service checkpoints that exit while keeping the session
unfinished. Cloud's journal permits this specific exited session to retain access to the game;
other retries, launches and maintenance remain fenced by the existing session/Cloud reservations.
The session is finalized only after sync succeeds or returns its durable pending/error state.
There is no unreserved gap between game exit and Cloud work. Catalog rejects a late callback that
would change a verified exited runtime back to running during this interval.

Sync time does not add playtime. Quit's grace/force timers end when the game exits, independently
of post-exit sync. Cancelling sync joins its worker and retains its pending journal; launcher
shutdown can leave that recoverable work behind. A checkpoint failure keeps the exited session
reserved for retry. On startup, runner recovery precedes Cloud claim recovery and post-exit sync,
and the install queue starts only after session recovery. Runner recovery retains a previously
verified exit code/forced outcome, while an exit not observed before restart remains unknown.

The journal retains the existing encoded `preparingSessionID` name for compatibility; it now
denotes the caller's reservation before launch **or** after verified runtime exit. Root access
must still independently verify ownership and stopped writers. A stored exit flag alone is not
filesystem/process authorization.

## Validation

Five added session tests exercise conflict→offline launch, exact retry authorization, held
post-exit sync and its durable reservation, cancellation with pending work, and restart with an
exited session plus interrupted Cloud claim. They use real Catalog transactions and simulated
Cloud/runner boundaries; the coordinator's separate tests cover actual staged file application.
Protocol-dispatched Retry/Play offline calls are exercised explicitly. A runner test verifies
preservation of clean, failed and forced exit results across recovery.

Full regression passed: 150 package XCTest tests (3 existing integration skips), 5 Swift Testing
tests and 55 app tests, no failures. `/tmp/bigscreen-session-cloud-final-tests.log`.

## Still required

The live app does not yet inject the Cloud coordinator. Production owned-root and save-format
validation, controller-accessible status/conflict/retry/offline controls, and app lifecycle wiring
are next. Games without declared Cloud paths can still launch; the page must show unsupported
coverage honestly. No live Steam upload, deletion or restoration is claimed by these tests.
