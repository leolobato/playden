import XCTest
import Darwin
import Domain
@testable import Installs

final class SteamSaveAccountTests: XCTestCase {
    private func folder() throws -> URL {
        let pointer = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    func testInitializeOnceAndKeepExistingRuntimeIdentityUnchanged() async throws {
        let root = try folder(), store = SaveStore()
        let first = try await store.steamLocalAccountID(roots: [.bottle: root])
        let path = root.appendingPathComponent("drive_c/Program Files (x86)/Steam/userdata/0/settings/configs.user.ini")
        let original = try Data(contentsOf: path)
        let second = try await store.steamLocalAccountID(roots: [.bottle: root])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first >> 32, 0x01100001)
        XCTAssertEqual(try Data(contentsOf: path), original)
    }
    func testReadsRuntimeINIAndRejectsInvalidOrDuplicateIdentity() throws {
        let valid = "[user::general]\r\n# Steam64 format\r\naccount_steamid=76561198012345678\r\n"
        XCTAssertEqual(try SaveStore.steamLocalAccountID(in: Data(valid.utf8)), 76_561_198_012_345_678)
        for text in ["", valid + "account_steamid=76561198012345679\n", valid.replacingOccurrences(of: "76561198012345678", with: "0"), valid.replacingOccurrences(of: "76561198012345678", with: "../outside")] {
            XCTAssertThrowsError(try SaveStore.steamLocalAccountID(in: Data(text.utf8)))
        }
    }
    func testSymlinkCannotRedirectAccountSettings() async throws {
        let root = try folder(), outside = try folder(), store = SaveStore()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("drive_c"), withDestinationURL: outside)
        do { _ = try await store.steamLocalAccountID(roots: [.bottle: root]); XCTFail("Followed a symlink") }
        catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testReadOnlyDiagnosticDoesNotInitializeAccount() async throws {
        let root = try folder(), store = SaveStore()
        do { _ = try await store.steamLocalAccountID(roots: [.bottle: root], createIfMissing: false); XCTFail("Expected missing identity") }
        catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
