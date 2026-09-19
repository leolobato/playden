import XCTest
import Domain
import Runner
@testable import Playden

@MainActor private final class ImmersiveLease: PrimaryDisplayHolding {
    nonisolated let target: GameDisplayTarget
    var releases = 0
    init(_ target: GameDisplayTarget) { self.target = target }
    func release() async { releases += 1 }
}

@MainActor final class ImmersiveDisplayTests: XCTestCase {
    private let screens = ["desk", "tv", "built-in"].enumerated().map {
        LauncherDisplayScreen(uuid: $0.element, frame: CGRect(x: $0.offset * 1920, y: 0, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: $0.offset * 1920, y: 0, width: 1920, height: 1080))
    }
    private func target(_ uuid: String) -> GameDisplayTarget {
        .init(bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), displayUUID: uuid)
    }
    func testDarkeningRequiresFullscreenOnTheLeasedDisplay() async throws {
        let controller = ImmersiveDisplayController()
        let lease = ImmersiveLease(target("tv"))
        var darkened: [LauncherDisplayScreen] = []
        var acquisitions = 0
        controller.acquire = { _ in acquisitions += 1; return lease }
        controller.darken = { darkened = $0 }
        controller.update(target: target("tv"), screens: screens)
        try await controller.waitUntilReady()
        XCTAssertTrue(darkened.isEmpty, "Windowed launchers and games must leave all displays visible")

        controller.updatePresentation(fullscreenDisplayUUID: "tv", screens: screens)
        XCTAssertEqual(darkened.map(\.uuid), ["desk", "built-in"])
        controller.updatePresentation(fullscreenDisplayUUID: nil, screens: screens)
        XCTAssertTrue(darkened.isEmpty, "Losing foreground visibility or leaving fullscreen reveals displays immediately")
        controller.updatePresentation(fullscreenDisplayUUID: "desk", screens: screens)
        XCTAssertTrue(darkened.isEmpty, "A game on another monitor must not end up behind a black panel")
        controller.updatePresentation(fullscreenDisplayUUID: "tv", screens: screens)
        XCTAssertEqual(darkened.count, 2)
        controller.updatePresentation(fullscreenDisplayUUID: "tv", screens: Array(screens.suffix(1)))
        XCTAssertTrue(darkened.isEmpty)
        XCTAssertEqual(acquisitions, 1)
        XCTAssertEqual(lease.releases, 0, "Window visibility must not reconfigure a running game's displays")
        await controller.shutdown()
    }

    func testFullscreenLostDuringAcquisitionDoesNotLeaveBlackPanels() async throws {
        let controller = ImmersiveDisplayController()
        let lease = ImmersiveLease(target("tv"))
        var darkened: [LauncherDisplayScreen] = []
        controller.darken = { darkened = $0 }
        controller.acquire = { [self] _ in
            controller.updatePresentation(fullscreenDisplayUUID: nil, screens: screens)
            return lease
        }
        controller.updatePresentation(fullscreenDisplayUUID: "tv", screens: screens)
        controller.update(target: target("tv"), screens: screens)
        try await controller.waitUntilReady()
        XCTAssertTrue(darkened.isEmpty)
        await controller.shutdown()
    }

    func testFullscreenGeometryRejectsWindowedMaximizedAndMisplacedWindows() {
        let display = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        XCTAssertTrue(ImmersiveFullscreenGeometry.fillsDisplay(display, display: display))
        XCTAssertTrue(ImmersiveFullscreenGeometry.fillsDisplay(display.insetBy(dx: 1, dy: 1), display: display))
        XCTAssertFalse(ImmersiveFullscreenGeometry.fillsDisplay(display.insetBy(dx: 200, dy: 150), display: display))
        XCTAssertFalse(ImmersiveFullscreenGeometry.fillsDisplay(CGRect(x: -1920, y: -1056, width: 1920, height: 1056), display: display))
        XCTAssertFalse(ImmersiveFullscreenGeometry.fillsDisplay(display.offsetBy(dx: 1920, dy: 0), display: display))
        XCTAssertFalse(ImmersiveFullscreenGeometry.fillsDisplay(CGRect(x: -1920, y: -1080, width: 3840, height: 1080), display: display))
        XCTAssertFalse(ImmersiveFullscreenGeometry.fillsDisplay(.zero, display: .zero))
    }

    func testEnableReconfigureDisconnectAndShutdownRestoreLeases() async throws {
        let controller = ImmersiveDisplayController()
        var leases: [ImmersiveLease] = [], darkened: [LauncherDisplayScreen] = []
        controller.acquire = { target in let lease = ImmersiveLease(target); leases.append(lease); return lease }
        controller.darken = { darkened = $0 }
        controller.updatePresentation(fullscreenDisplayUUID: "tv", screens: screens)
        controller.update(target: target("tv"), screens: screens)
        try await controller.waitUntilReady()
        XCTAssertEqual(darkened.map(\.uuid), ["desk", "built-in"])
        controller.update(target: target("tv"), screens: Array(screens.prefix(2)))
        XCTAssertEqual(darkened.map(\.uuid), ["desk"])
        XCTAssertEqual(leases.count, 1, "Geometry notifications must not reacquire the display lease")
        controller.updatePresentation(fullscreenDisplayUUID: "desk", screens: screens)
        controller.update(target: target("desk"), screens: screens)
        try await controller.waitUntilReady()
        XCTAssertEqual(leases[0].releases, 1)
        XCTAssertEqual(darkened.map(\.uuid), ["tv", "built-in"])
        controller.update(target: nil, screens: Array(screens.suffix(2)))
        XCTAssertTrue(darkened.isEmpty, "Unplugging the preferred screen immediately reveals the others")
        try await controller.waitUntilReady()
        XCTAssertEqual(leases[1].releases, 1)
        controller.updatePresentation(fullscreenDisplayUUID: "tv", screens: screens)
        controller.update(target: target("tv"), screens: screens)
        try await controller.waitUntilReady()
        await controller.shutdown(); await controller.shutdown()
        XCTAssertTrue(darkened.isEmpty)
        XCTAssertEqual(leases[2].releases, 1)
        controller.updatePresentation(fullscreenDisplayUUID: "desk", screens: screens)
        controller.update(target: target("desk"), screens: screens)
        XCTAssertNil(controller.activeDisplayUUID)
        XCTAssertEqual(leases.count, 3)
    }
    func testFailedPrimarySwitchNeverDarkensOtherScreens() async {
        let controller = ImmersiveDisplayController()
        var darkened: [LauncherDisplayScreen] = [], error: Error?
        controller.darken = { darkened = $0 }
        controller.acquire = { _ in throw CocoaError(.featureUnsupported) }
        controller.stateChanged = { _, failure in error = failure }
        controller.updatePresentation(fullscreenDisplayUUID: "tv", screens: screens)
        controller.update(target: target("tv"), screens: screens)
        do { try await controller.waitUntilReady(); XCTFail("Expected display failure") } catch {}
        XCTAssertNotNil(error)
        XCTAssertNil(controller.activeDisplayUUID)
        XCTAssertTrue(darkened.isEmpty)
        controller.update(target: nil, screens: screens)
        try? await controller.waitUntilReady()
        XCTAssertNil(error)
    }
    func testShutdownDuringAcquisitionReleasesLateLeaseWithoutDarkening() async throws {
        let controller = ImmersiveDisplayController(), lease = ImmersiveLease(target("tv"))
        var pending: CheckedContinuation<any PrimaryDisplayHolding, Never>?
        var darkened: [LauncherDisplayScreen] = []
        controller.acquire = { _ in await withCheckedContinuation { pending = $0 } }
        controller.darken = { darkened = $0 }
        controller.updatePresentation(fullscreenDisplayUUID: "tv", screens: screens)
        controller.update(target: target("tv"), screens: screens)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while pending == nil && ContinuousClock.now < deadline { await Task.yield() }
        let completion = try XCTUnwrap(pending)
        let shutdown = Task { await controller.shutdown() }
        await Task.yield()
        completion.resume(returning: lease)
        await shutdown.value
        XCTAssertEqual(lease.releases, 1)
        XCTAssertNil(controller.activeDisplayUUID)
        XCTAssertTrue(darkened.isEmpty)
    }
}
