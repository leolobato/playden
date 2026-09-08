import XCTest
import SwiftUI
import Domain
@testable import BigScreen

final class NotificationInteractionTests: XCTestCase {
    @MainActor func testRenderedToastWaitsForModalThenAutomaticallyDismisses() async throws {
        let model = LibraryModel()
        model.enqueueNotification(.init(source: .job(UUID()), tone: .success,
                                        title: "Download complete", detail: "A Short Hike"))
        model.show(.context)
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 560, height: 230),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NotificationToasts(model: model))
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(5200))
        XCTAssertEqual(model.notifications.count, 1, "A hidden toast must not time out behind a modal")
        model.panel = nil
        let shownAt = ContinuousClock.now
        while !model.notifications.isEmpty && ContinuousClock.now - shownAt < .seconds(8) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(model.notifications.isEmpty, "The rendered toast must dismiss without user input")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - shownAt, .milliseconds(4800))
    }
    @MainActor func testRestoredHistoryDoesNotReplayAndRetryCanReportNewOutcome() {
        let model = LibraryModel()
        var job = JobRecord(gameID: model.games[0].id)
        job.state = .failed
        model.receiveInstallNotifications([job])
        model.receiveInstallNotifications([job])
        XCTAssertTrue(model.notifications.isEmpty)
        job.state = .running; model.receiveInstallNotifications([job])
        job.state = .failed; model.receiveInstallNotifications([job])
        XCTAssertEqual(model.notifications.count, 1)
        let oldID = model.notifications[0].id
        job.state = .running; model.receiveInstallNotifications([job])
        job.state = .completed; model.receiveInstallNotifications([job])
        XCTAssertEqual(model.notifications.count, 1)
        XCTAssertEqual(model.notifications[0].title, "Download complete")
        model.expireNotification(oldID)
        XCTAssertEqual(model.notifications.count, 1)
    }

    @MainActor func testHiddenNotificationsKeepTheirLifetimeAndNeverDismissPanels() throws {
        let model = LibraryModel()
        model.enqueueNotification(.init(source: .job(UUID()), tone: .success, title: "Download complete", detail: "A Short Hike"))
        let id = try XCTUnwrap(model.visibleNotification?.id)
        model.show(.context)
        XCTAssertNil(model.visibleNotification)
        model.expireNotification(id)
        XCTAssertEqual(model.notifications.count, 1)
        XCTAssertEqual(model.panel, .context)
        model.panel = nil; model.launcherActive = false
        XCTAssertNil(model.visibleNotification)
        model.expireNotification(id)
        model.launcherActive = true
        model.session.phase = .running
        XCTAssertNil(model.visibleNotification)
        model.session.phase = .idle
        XCTAssertEqual(model.visibleNotification?.id, id)
        model.expireNotification(id)
        XCTAssertTrue(model.notifications.isEmpty)
    }

    @MainActor func testControllerReconnectPreservesFocusAndClearsPersistentWarning() {
        let model = LibraryModel()
        model.selectTab(.library); model.perform(.move(.right))
        let focus = model.focusedGame?.id
        model.receiveControllerConnection(name: "DUALSHOCK 4", playStation: true)
        XCTAssertEqual(model.visibleNotification?.title, "Controller connected")
        model.receiveControllerConnection(name: "DUALSHOCK 4", playStation: true)
        XCTAssertEqual(model.notifications.count, 1)
        model.receiveControllerConnection(name: nil, playStation: false)
        XCTAssertTrue(model.controllerDisconnected)
        XCTAssertTrue(model.notifications.isEmpty)
        model.enqueueNotification(.init(source: .job(UUID()), tone: .success, title: "Download complete", detail: "A Short Hike"))
        XCTAssertNil(model.visibleNotification)
        model.receiveControllerConnection(name: nil, playStation: false)
        XCTAssertTrue(model.controllerDisconnected)
        model.receiveControllerConnection(name: "DUALSHOCK 4", playStation: true)
        XCTAssertFalse(model.controllerDisconnected)
        XCTAssertEqual(model.focusedGame?.id, focus)
        XCTAssertEqual(model.tab, .library)
        XCTAssertNil(model.panel)
        XCTAssertEqual(model.notifications.map(\.title), ["Download complete", "Controller connected"])
    }
}
