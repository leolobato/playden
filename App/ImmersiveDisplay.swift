import AppKit
import Domain
import Runner

/// Serializes display leases so changing monitors never stacks temporary layouts.
@MainActor final class ImmersiveDisplayController {
    var acquire: (GameDisplayTarget) async throws -> any PrimaryDisplayHolding = { _ in
        throw OperationFailure(stage: "Immersive mode", reason: "The display helper is unavailable.", output: "")
    }
    var interrupted: () -> Void = {}
    var stateChanged: (Bool, Error?) -> Void = { _, _ in }
    private(set) var activeDisplayUUID: String?
    private(set) var requestedUUID: String?
    private var lease: (any PrimaryDisplayHolding)?
    private var monitor: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var stopped = false
    private var failure: Error?

    func update(target: GameDisplayTarget?) {
        guard !stopped else { return }
        let uuid = target?.displayUUID
        guard uuid != requestedUUID else { return }
        monitor?.cancel()
        requestedUUID = uuid; generation += 1
        let revision = generation, previous = worker
        stateChanged(true, nil)
        worker = Task { @MainActor in
            await previous?.value
            guard generation == revision, !stopped else { return }
            let old = lease; lease = nil; activeDisplayUUID = nil
            await old?.release()
            guard generation == revision, !stopped else { return }
            failure = nil
            if let target, let uuid {
                do {
                    let acquired = try await acquire(target)
                    guard generation == revision, !stopped else { await acquired.release(); return }
                    lease = acquired; activeDisplayUUID = uuid
                    monitor = Task { @MainActor [weak self] in
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                            guard let self else { return }
                            await self.checkLease()
                        }
                    }
                } catch { failure = error }
            }
            guard generation == revision, !stopped else { return }
            stateChanged(false, failure)
        }
    }

    func checkLease() async {
        let revision = generation
        guard let lease, !(await lease.isAlive()), revision == generation, !stopped else { return }
        monitor?.cancel()
        self.lease = nil; activeDisplayUUID = nil
        // Block fallback acquisition until the owner turns the preference off.
        await lease.release()
        guard revision == generation, !stopped else { return }
        interrupted()
    }

    func waitUntilReady() async throws {
        var revision: Int
        repeat {
            revision = generation
            await worker?.value
            try Task.checkCancellation()
        } while revision != generation
        if let failure { throw failure }
    }

    func shutdown() async {
        monitor?.cancel()
        stopped = true; generation += 1; requestedUUID = nil
        await worker?.value
        let old = lease; lease = nil; activeDisplayUUID = nil
        await old?.release()
        stateChanged(false, nil)
    }

}
