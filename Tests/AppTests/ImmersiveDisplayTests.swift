import XCTest
import Domain
import Runner
@testable import Playden

@MainActor private final class ImmersiveLease: PrimaryDisplayHolding {
    nonisolated let target: GameDisplayTarget
    var releases = 0
    var alive = true
    init(_ target: GameDisplayTarget) { self.target = target }
    func release() async { releases += 1 }
    func isAlive() async -> Bool { alive }
}

@MainActor final class ImmersiveDisplayTests: XCTestCase {
    private func target(_ uuid: String) -> GameDisplayTarget {
        .init(bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), displayUUID: uuid)
    }
    func testEnableReconfigureAndShutdownRestoreLeases() async throws {
        let controller = ImmersiveDisplayController()
        var leases: [ImmersiveLease] = []
        controller.acquire = { target in let lease = ImmersiveLease(target); leases.append(lease); return lease }
        controller.update(target: target("tv"))
        try await controller.waitUntilReady()
        XCTAssertEqual(controller.activeDisplayUUID, "tv")
        controller.update(target: target("tv"))
        XCTAssertEqual(leases.count, 1, "Topology notifications must not reacquire the lease")
        controller.update(target: target("desk"))
        try await controller.waitUntilReady()
        XCTAssertEqual(leases[0].releases, 1)
        XCTAssertEqual(controller.activeDisplayUUID, "desk")
        controller.update(target: nil)
        try await controller.waitUntilReady()
        XCTAssertEqual(leases[1].releases, 1)
        controller.update(target: target("tv"))
        try await controller.waitUntilReady()
        await controller.shutdown(); await controller.shutdown()
        XCTAssertEqual(leases[2].releases, 1)
        controller.update(target: target("desk"))
        XCTAssertNil(controller.activeDisplayUUID)
        XCTAssertEqual(leases.count, 3)
    }
    func testFailedAcquisitionReportsErrorAndCanBeDisabled() async {
        let controller = ImmersiveDisplayController()
        var error: Error?
        controller.acquire = { _ in throw CocoaError(.featureUnsupported) }
        controller.stateChanged = { _, failure in error = failure }
        controller.update(target: target("tv"))
        do { try await controller.waitUntilReady(); XCTFail("Expected display failure") } catch {}
        XCTAssertNotNil(error)
        XCTAssertNil(controller.activeDisplayUUID)
        controller.update(target: nil)
        try? await controller.waitUntilReady()
        XCTAssertNil(error)
    }
    func testHelperExitEndsImmersiveModeOnceAfterRestoration() async throws {
        let controller = ImmersiveDisplayController(), lease = ImmersiveLease(target("tv"))
        var interruptions = 0
        controller.acquire = { _ in lease }
        controller.interrupted = {
            XCTAssertEqual(lease.releases, 1)
            interruptions += 1
            controller.update(target: nil)
        }
        controller.update(target: target("tv"))
        try await controller.waitUntilReady()
        await controller.checkLease()
        XCTAssertEqual(interruptions, 0)
        lease.alive = false
        await controller.checkLease()
        await controller.checkLease()
        try await controller.waitUntilReady()
        XCTAssertEqual(interruptions, 1)
        XCTAssertNil(controller.activeDisplayUUID)
        await controller.shutdown()
        XCTAssertEqual(lease.releases, 1)
    }
    func testShutdownDuringAcquisitionReleasesLateLease() async throws {
        let controller = ImmersiveDisplayController(), lease = ImmersiveLease(target("tv"))
        var pending: CheckedContinuation<any PrimaryDisplayHolding, Never>?
        controller.acquire = { _ in await withCheckedContinuation { pending = $0 } }
        controller.update(target: target("tv"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while pending == nil && ContinuousClock.now < deadline { await Task.yield() }
        let completion = try XCTUnwrap(pending)
        let shutdown = Task { await controller.shutdown() }
        await Task.yield()
        completion.resume(returning: lease)
        await shutdown.value
        XCTAssertEqual(lease.releases, 1)
        XCTAssertNil(controller.activeDisplayUUID)
    }
}
