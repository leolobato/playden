import XCTest
import SteamCore
@testable import Sources

final class SteamConnectionDiagnosticsTests: XCTestCase {
    func testErrorsDoNotExposeServerMessagesOrURLs() {
        let secret = "sensitive-fixture"
        XCTAssertEqual(SteamConnectionDiagnostics.summary(SteamError.http(status: 401, url: "https://example.com/\(secret)")), "HTTP status=401")
        XCTAssertEqual(SteamConnectionDiagnostics.summary(SteamError.authFailed(secret)), "credentials rejected")
        XCTAssertEqual(SteamConnectionDiagnostics.summary(SteamError.eresult(.expired, context: secret)), "Steam result=27")
        XCTAssertEqual(SteamConnectionDiagnostics.summary(SteamError.protocolError(secret)), "protocol error")
    }
    func testReleaseLogRotatesAndRetainsLatestAttempt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = SteamConnectionDiagnostics(root: root, limit: 160)
        log.record("first " + String(repeating: "a", count: 80))
        log.record("second " + String(repeating: "b", count: 80))
        log.record("third " + String(repeating: "c", count: 80))
        let current = try String(contentsOf: root.appendingPathComponent("steam-connections.log"), encoding: .utf8)
        let previous = try String(contentsOf: root.appendingPathComponent("steam-connections.previous.log"), encoding: .utf8)
        XCTAssertTrue(current.contains("third"))
        XCTAssertTrue(previous.contains("second"))
        XCTAssertFalse(previous.contains("first"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }
}
