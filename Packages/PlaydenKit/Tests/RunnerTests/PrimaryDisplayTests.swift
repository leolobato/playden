import XCTest
import Domain
@testable import Runner

final class PrimaryDisplayTests: XCTestCase {
    private let uuid = "C1A51D2B-DB73-484B-8861-6BDF0DCEEB44"
    private var screens: [PrimaryDisplayScreen] { [
        .init(id: 2, uuid: "main", x: 0, y: 0, width: 3008, height: 1692, isMain: true),
        .init(id: 1, uuid: "builtin", x: 3008, y: 458, width: 1512, height: 982),
        .init(id: 3, uuid: uuid, x: -1920, y: 0, width: 1920, height: 1080)
    ] }
    func testTranslationMakesPreferredPrimaryAndPreservesEveryRelativeOriginAndSize() throws {
        let layout = try PrimaryDisplayLayout(screens: screens, targetUUID: uuid.lowercased())
        XCTAssertTrue(layout.changesPrimary)
        XCTAssertEqual(layout.proposed.first?.id, 3)
        XCTAssertEqual(layout.proposed.first?.x, 0)
        XCTAssertEqual(layout.proposed.first?.y, 0)
        XCTAssertEqual(layout.proposed.filter(\.isMain).map(\.id), [3])
        for original in screens {
            let proposed = try XCTUnwrap(layout.proposed.first { $0.id == original.id })
            XCTAssertEqual(proposed.x, original.x + 1920)
            XCTAssertEqual(proposed.y, original.y)
            XCTAssertEqual(proposed.width, original.width)
            XCTAssertEqual(proposed.height, original.height)
        }
        XCTAssertFalse(try PrimaryDisplayLayout(screens: screens, targetUUID: "main").changesPrimary)
    }
    func testVerticalAndPositiveOriginLayouts() throws {
        let screens: [PrimaryDisplayScreen] = [
            .init(id: 1, uuid: "main", x: 0, y: 0, width: 1440, height: 900, isMain: true),
            .init(id: 2, uuid: "target", x: 1440, y: -1080, width: 1920, height: 1080)
        ]
        let layout = try PrimaryDisplayLayout(screens: screens, targetUUID: "target")
        let oldMain = try XCTUnwrap(layout.proposed.first { $0.id == 1 })
        XCTAssertEqual(oldMain.x, -1440)
        XCTAssertEqual(oldMain.y, 1080)
    }
    func testDisconnectedMirroredAndAmbiguousDisplaysAreRejected() {
        XCTAssertThrowsError(try PrimaryDisplayLayout(screens: screens, targetUUID: "disconnected"))
        XCTAssertThrowsError(try PrimaryDisplayLayout(screens: screens + [screens[0]], targetUUID: uuid))
        let mirrored = PrimaryDisplayScreen(id: 4, uuid: "mirror", x: 0, y: 0, width: 1920, height: 1080, isMirrored: true)
        XCTAssertThrowsError(try PrimaryDisplayLayout(screens: screens + [mirrored], targetUUID: uuid))
        XCTAssertThrowsError(try PrimaryDisplayLayout(screens: Array(screens.dropFirst()), targetUUID: uuid))
    }
    // These executable fixtures never call display APIs. They exercise the real pipe lifecycle.
    private func fixture(body: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Playden-primary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("helper")
        try Data(("#!/bin/sh\nprintf '%s' $$ > '\(root.path)/pid'\n" + body).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (script, root.appendingPathComponent("pid"))
    }
    private var target: GameDisplayTarget { .init(bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                                primaryBounds: CGRect(x: 0, y: 0, width: 3008, height: 1692), displayUUID: uuid) }
    func testAcknowledgementRebasesTargetAndReleaseWaitsForHelperExit() async throws {
        let json = String(decoding: try JSONEncoder().encode(PrimaryDisplayScreen(id: 3, uuid: uuid, x: 0, y: 0, width: 1920, height: 1080, isMain: true)), as: UTF8.self)
        let (helper, pidFile) = try fixture(body: "printf '%s\\n' '\(json)'\ncat >/dev/null\n")
        let lease = try await TemporaryPrimaryDisplay.acquire(target: target, helper: helper)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(lease.target.bounds.origin, .zero)
        XCTAssertEqual(lease.target.primaryBounds, lease.target.bounds)
        XCTAssertNotNil(RuntimeProcessInspector().identity(of: pid))
        await lease.release()
        await lease.release()
        XCTAssertNil(RuntimeProcessInspector().identity(of: pid))
    }
    func testImmersiveHelperReceivesModeAndReportsExit() async throws {
        let json = String(decoding: try JSONEncoder().encode(PrimaryDisplayScreen(id: 3, uuid: uuid, x: 0, y: 0, width: 1920, height: 1080, isMain: true)), as: UTF8.self)
        let (helper, _) = try fixture(body: "test \"$1\" = --immersive || exit 2\nprintf '%s\\n' '\(json)'\ncat >/dev/null\n")
        let lease = try await TemporaryPrimaryDisplay.acquire(target: target, helper: helper, disconnectOtherDisplays: true)
        let alive = await lease.isAlive()
        XCTAssertTrue(alive)
        await lease.release()
        let ended = await lease.isAlive()
        XCTAssertFalse(ended)
    }

    func testHelperConfigurationErrorIsPreservedForTheUI() async throws {
        let reason = "Commit display configuration failed (Core Graphics error 1001)."
        let json = String(decoding: try JSONEncoder().encode(PrimaryDisplayHelperFailure(error: reason)), as: UTF8.self)
        let (helper, _) = try fixture(body: "printf '%s\\n' '\(json)'\ncat >/dev/null\n")
        do {
            _ = try await TemporaryPrimaryDisplay.acquire(target: target, helper: helper, disconnectOtherDisplays: true)
            XCTFail("Expected configuration error")
        } catch let failure as OperationFailure {
            XCTAssertEqual(failure.reason, reason)
        }
    }

    func testMalformedReadinessAndCancellationEndHelperBeforeReturning() async throws {
        for cancel in [false, true] {
            let (helper, pidFile) = try fixture(body: cancel ? "cat >/dev/null\n" : "printf 'invalid\\n'\ncat >/dev/null\n")
            let target = target
            let task = Task { try await TemporaryPrimaryDisplay.acquire(target: target, helper: helper) }
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
            if cancel { task.cancel() }
            do { _ = try await task.value; XCTFail("Unexpected acquisition") } catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
            }
            XCTAssertNil(RuntimeProcessInspector().identity(of: pid))
        }
    }
    func testRenamedWineLoaderRemainsEligibleForBottleAndArgvClassification() {
        XCTAssertTrue(RuntimeProcessInspector.isWineExecutable("/private/var/folders/T/winetemp-abc/wineloader"))
        XCTAssertTrue(RuntimeProcessInspector.isWineExecutable("/Applications/CrossOver.app/bin/wine64"))
        XCTAssertFalse(RuntimeProcessInspector.isWineExecutable("/usr/bin/python3"))
        XCTAssertEqual(RuntimeProcessInspector.kind(#"Z:\Volumes\VM\Playden\games\playden-steam-208670\game\bladesoftime.exe"#), .game)
        XCTAssertEqual(RuntimeProcessInspector.kind(#"C:\windows\system32\explorer.exe"#), .service)
    }
}
