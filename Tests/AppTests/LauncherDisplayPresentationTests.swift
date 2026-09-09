import XCTest
import Domain
import Runner
@testable import Playden

@MainActor private final class WindowFixture: LauncherWindowControlling {
    let original = [
        LauncherDisplayScreen(uuid: "lg", frame: CGRect(x: 0, y: 0, width: 3008, height: 1692), visibleFrame: CGRect(x: 0, y: 0, width: 3008, height: 1692)),
        LauncherDisplayScreen(uuid: "asus", frame: CGRect(x: -1920, y: 612, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 612, width: 1920, height: 1080))
    ]
    var launcherScreens: [LauncherDisplayScreen]
    var launcherFrame = CGRect(x: -1800, y: 700, width: 1280, height: 720)
    var launcherFullscreen = false
    var launcherFullscreenTransitioning = false
    var normalFrame = CGRect.zero
    var events: [String] = []
    var rejectEntry = false
    var cancelOnExit = false
    init() { launcherScreens = original }
    var launcherScreen: LauncherDisplayScreen? {
        launcherScreens.first { $0.frame.contains(CGPoint(x: launcherFrame.midX, y: launcherFrame.midY)) }
    }
    func setLauncherFullscreen(_ enabled: Bool) {
        events.append(enabled ? "enter" : "leave")
        if enabled && rejectEntry { return }
        if enabled {
            normalFrame = launcherFrame
            launcherFrame = launcherScreen!.frame
        } else {
            launcherFrame = normalFrame
            if cancelOnExit { withUnsafeCurrentTask { $0?.cancel() } }
        }
        launcherFullscreen = enabled
    }
    func showLauncherForRestore() async throws { events.append("show") }
    func setLauncherFrame(_ frame: CGRect) { events.append("position"); launcherFrame = frame }
    func switchLayout() {
        XCTAssertFalse(launcherFullscreen, "Never change the main display while Playden owns a fullscreen Space")
        events.append("switch")
        launcherScreens = original.map { screen in
            let frame = screen.frame.offsetBy(dx: 1920, dy: -612)
            return .init(uuid: screen.uuid, frame: frame, visibleFrame: frame)
        }
        // Simulate AppKit moving the window to the old primary. The presenter must repair it.
        launcherFrame = CGRect(x: 2100, y: 100, width: 1280, height: 720)
    }
    func revertLayout() {
        XCTAssertFalse(launcherFullscreen)
        events.append("revert"); launcherScreens = original
        launcherFrame = CGRect(x: 100, y: 100, width: 1280, height: 720)
    }
}
@MainActor private final class DisplayLeaseFixture: PrimaryDisplayHolding {
    nonisolated let target = GameDisplayTarget(bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let window: WindowFixture
    var releases = 0
    init(window: WindowFixture) { self.window = window }
    func release() { releases += 1; window.revertLayout() }
}

@MainActor final class LauncherDisplayPresentationTests: XCTestCase {
    func testLauncherStaysOnGameDesktopAndRestoresFullscreenOnlyAtExit() async throws {
        for fullscreen in [false, true] {
            let window = WindowFixture(), presentation = LauncherDisplayPresentation()
            presentation.window = window
            let originalFrame = window.launcherFrame
            if fullscreen { window.setLauncherFullscreen(true) }
            window.events = []
            let base = DisplayLeaseFixture(window: window)
            let lease = try await presentation.acquire(target: base.target) { _ in
                window.switchLayout(); return base
            }
            XCTAssertEqual(window.launcherScreen?.uuid, "asus")
            XCTAssertFalse(window.launcherFullscreen, "No separate fullscreen Space during game handoff")
            if fullscreen { XCTAssertEqual(window.events, ["leave", "switch", "position"]) }
            XCTAssertEqual(window.launcherFrame, originalFrame.offsetBy(dx: 1920, dy: -612))
            await lease.release(); await lease.release()
            XCTAssertEqual(base.releases, 1)
            XCTAssertEqual(window.launcherScreen?.uuid, "asus")
            XCTAssertEqual(window.launcherFullscreen, fullscreen)
            if fullscreen { window.setLauncherFullscreen(false) }
            XCTAssertEqual(window.launcherFrame, originalFrame)
            XCTAssertTrue(presentation.consumePreservedWindow())
            XCTAssertFalse(presentation.consumePreservedWindow())
            XCTAssertFalse(presentation.isChanging)
        }
    }
    func testFailedNativeSwitchRestoresFullscreenWithoutStartingGame() async throws {
        let window = WindowFixture(), presentation = LauncherDisplayPresentation()
        presentation.window = window; window.setLauncherFullscreen(true)
        do {
            _ = try await presentation.acquire(target: DisplayLeaseFixture(window: window).target) { _ in throw CocoaError(.featureUnsupported) }
            XCTFail("Unexpected acquisition")
        } catch {}
        XCTAssertTrue(window.launcherFullscreen)
        XCTAssertEqual(window.launcherScreen?.uuid, "asus")
        XCTAssertFalse(presentation.isChanging)
    }
    func testFailedFullscreenRestoreReportsErrorAfterReleasingNativeLease() async throws {
        let window = WindowFixture(), presentation = LauncherDisplayPresentation()
        presentation.window = window; window.setLauncherFullscreen(true)
        let base = DisplayLeaseFixture(window: window)
        var failures: [Error] = []
        presentation.reportFailure = { failures.append($0) }
        let lease = try await presentation.acquire(target: base.target) { _ in
            window.switchLayout(); return base
        }
        window.rejectEntry = true
        await lease.release()
        XCTAssertEqual(base.releases, 1)
        XCTAssertEqual(window.launcherScreens, window.original)
        XCTAssertEqual(window.launcherScreen?.uuid, "asus")
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(presentation.isChanging)
    }
    func testCancelledLaunchRollsBackAndRestoresFullscreen() async throws {
        let window = WindowFixture(), presentation = LauncherDisplayPresentation()
        presentation.window = window; window.setLauncherFullscreen(true)
        let base = DisplayLeaseFixture(window: window)
        let task = Task { @MainActor in
            try await presentation.acquire(target: base.target) { _ in
                window.switchLayout()
                withUnsafeCurrentTask { $0?.cancel() }
                return base
            }
        }
        do { _ = try await task.value; XCTFail("Unexpected acquisition") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(base.releases, 1)
        XCTAssertEqual(window.launcherScreens, window.original)
        XCTAssertTrue(window.launcherFullscreen)
        XCTAssertEqual(window.launcherScreen?.uuid, "asus")
    }
    func testCancellationWhileLeavingFullscreenPreservesItsNormalFrame() async throws {
        let window = WindowFixture(), presentation = LauncherDisplayPresentation()
        presentation.window = window
        let originalFrame = window.launcherFrame
        window.setLauncherFullscreen(true); window.cancelOnExit = true
        let task = Task { @MainActor in
            try await presentation.acquire(target: DisplayLeaseFixture(window: window).target) { _ in
                XCTFail("Cancelled presentation must not switch the main display")
                return DisplayLeaseFixture(window: window)
            }
        }
        do { _ = try await task.value; XCTFail("Unexpected acquisition") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(window.launcherFullscreen)
        window.cancelOnExit = false; window.setLauncherFullscreen(false)
        XCTAssertEqual(window.launcherFrame, originalFrame)
        XCTAssertFalse(presentation.isChanging)
    }
}
