import XCTest
@testable import Runner

@MainActor final class ImmersiveDisplayConfigurationTests: XCTestCase {
    private let desk = PrimaryDisplayScreen(id: 1, uuid: "desk", x: 0, y: 0, width: 1920, height: 1080, isMain: true)
    private let tv = PrimaryDisplayScreen(id: 2, uuid: "tv", x: 1920, y: 0, width: 1920, height: 1080)

    func testDisconnectRestoresOriginalOriginsUsingCurrentIDs() throws {
        var calls: [[ImmersiveDisplayConfiguration.Change]] = []
        var screens = [desk, tv]
        let lease = ImmersiveDisplayConfiguration(targetUUID: "TV", online: { screens },
            allDisplays: { ["desk": 11, "tv": 2, "previously-disabled": 3] }, configure: { calls.append($0) })
        try lease.enforce()
        XCTAssertEqual(calls, [[.init(id: 2, enabled: true, origin: .zero), .init(id: 1, enabled: false)]])
        screens = [tv]
        try lease.enforce()
        XCTAssertEqual(calls.count, 1)
        try lease.restore(); try lease.restore()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1], [.init(id: 11, enabled: true, origin: .zero),
                                  .init(id: 2, enabled: true, origin: CGPoint(x: 1920, y: 0))])
    }

    func testRestoreUsesCapturedIDWhenDisabledDisplayLosesItsUUID() throws {
        var calls: [[ImmersiveDisplayConfiguration.Change]] = []
        let lease = ImmersiveDisplayConfiguration(targetUUID: "tv", online: { [self.desk, self.tv] },
            allDisplays: { [ImmersiveDisplayConfiguration.offlineKey(1): 1, "tv": 2] },
            configure: { calls.append($0) })
        try lease.enforce()
        try lease.restore()
        XCTAssertEqual(calls[1].map(\.id), [1, 2])
        XCTAssertTrue(calls[1].allSatisfy(\.enabled))
    }

    func testRestoreDoesNotUseCapturedIDNowOwnedByAnotherMonitor() throws {
        var calls: [[ImmersiveDisplayConfiguration.Change]] = []
        let lease = ImmersiveDisplayConfiguration(targetUUID: "tv", online: { [self.desk, self.tv] },
            allDisplays: { ["replacement": 1, "tv": 2] }, configure: { calls.append($0) })
        try lease.enforce()
        try lease.restore()
        XCTAssertEqual(calls[1].map(\.id), [2])
    }

    func testUnpluggedTargetFailsWithoutDisablingFallbackAndRestoresOthers() throws {
        var screens = [desk, tv]
        var calls: [[ImmersiveDisplayConfiguration.Change]] = []
        let lease = ImmersiveDisplayConfiguration(targetUUID: "tv", online: { screens },
            allDisplays: { ["desk": 1] }, configure: { calls.append($0) })
        try lease.enforce()
        screens = []
        XCTAssertThrowsError(try lease.enforce())
        XCTAssertEqual(calls.count, 1)
        try lease.restore()
        XCTAssertEqual(calls.last, [.init(id: 1, enabled: true, origin: .zero)])
    }

    func testHotplugAndWakeAreDisabledAndRestored() throws {
        var screens = [desk, tv]
        var calls: [[ImmersiveDisplayConfiguration.Change]] = []
        let lease = ImmersiveDisplayConfiguration(targetUUID: "tv", online: { screens },
            allDisplays: { ["desk": 1, "tv": 2, "new": 3] }, configure: { calls.append($0) })
        try lease.enforce()
        screens.append(.init(id: 3, uuid: "new", x: -1000, y: 0, width: 1000, height: 800))
        try lease.enforce()
        XCTAssertEqual(calls[1].filter { !$0.enabled }.map(\.id), [1, 3])
        try lease.restore()
        XCTAssertEqual(Set(calls[2].map(\.id)), [1, 2, 3])
        XCTAssertTrue(calls[2].allSatisfy(\.enabled))
    }

    func testFailedCommitRetainsRestorationAndFailedRestoreCanRetry() throws {
        var fail = true
        var calls = 0
        let lease = ImmersiveDisplayConfiguration(targetUUID: "tv", online: { [self.desk, self.tv] },
            allDisplays: { ["desk": 1, "tv": 2] }, configure: { _ in
                calls += 1
                if fail { throw CocoaError(.featureUnsupported) }
            })
        XCTAssertThrowsError(try lease.enforce())
        XCTAssertThrowsError(try lease.restore())
        fail = false
        try lease.restore(); try lease.restore()
        XCTAssertEqual(calls, 3)
    }
}
