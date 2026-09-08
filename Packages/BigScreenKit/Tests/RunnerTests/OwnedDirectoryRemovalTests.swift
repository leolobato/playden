import XCTest
import Darwin
import Domain
@testable import Runner

final class OwnedDirectoryRemovalTests: XCTestCase {
    func testUnreadableParentIsNotMistakenForSuccessfulRemoval() throws {
        guard getuid() != 0 else { throw XCTSkip("Permission denial requires an unprivileged process") }
        let root = try root(), directory = root.appendingPathComponent("game"), receipt = root.appendingPathComponent("removing.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let removal = OwnedDirectoryRemoval(directory: directory, receipt: receipt, owner: UUID())
        try removal.begin {}
        XCTAssertEqual(chmod(root.path, 0), 0)
        defer { chmod(root.path, 0o700) }
        XCTAssertThrowsError(try removal.removeRemainingFiles())
        XCTAssertThrowsError(try removal.finish())
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OwnedRemoval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }; return root
    }
    func testExternalReceiptRecoversWhenInternalMarkerWasAlreadyDeleted() throws {
        let root = try root(), directory = root.appendingPathComponent("game"), receipt = root.appendingPathComponent("removing.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let marker = directory.appendingPathComponent("owner"), content = directory.appendingPathComponent("save")
        try Data([1]).write(to: marker); try Data([2]).write(to: content)
        let owner = UUID(), first = OwnedDirectoryRemoval(directory: directory, receipt: receipt, owner: UUID())
        XCTAssertThrowsError(try first.begin { throw SourceFailure.unavailable })
        XCTAssertFalse(first.isPending)
        let removal = OwnedDirectoryRemoval(directory: directory, receipt: receipt, owner: owner)
        try removal.begin { XCTAssertEqual(try Data(contentsOf: marker), Data([1])) }
        try FileManager.default.removeItem(at: marker)
        let reopened = OwnedDirectoryRemoval(directory: directory, receipt: receipt, owner: owner)
        try reopened.begin { XCTFail("Internal marker need not survive partial deletion") }
        XCTAssertThrowsError(try first.verify())
        try reopened.removeRemainingFiles()
        XCTAssertTrue(reopened.isPending); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try reopened.finish(); XCTAssertFalse(reopened.isPending)
        try reopened.removeRemainingFiles(); try reopened.finish()
    }
    func testReceiptCannotDeleteReplacementDirectoryOrFollowSymlinks() throws {
        let root = try root(), directory = root.appendingPathComponent("game"), receipt = root.appendingPathComponent("removing.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let removal = OwnedDirectoryRemoval(directory: directory, receipt: receipt, owner: UUID())
        try removal.begin {}
        try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let content = directory.appendingPathComponent("unrelated"); try Data([42]).write(to: content)
        XCTAssertThrowsError(try removal.removeRemainingFiles()); XCTAssertEqual(try Data(contentsOf: content), Data([42]))
        try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("replacement"))
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root.appendingPathComponent("old"))
        XCTAssertThrowsError(try removal.removeRemainingFiles())
        try FileManager.default.moveItem(at: receipt, to: root.appendingPathComponent("receipt-backup"))
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: root.appendingPathComponent("receipt-backup"))
        XCTAssertThrowsError(try removal.verify())
    }
}
