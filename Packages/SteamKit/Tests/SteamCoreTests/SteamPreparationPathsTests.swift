import XCTest
@testable import SteamCore

final class SteamPreparationPathsTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testChecksEveryParentAndRejectsEscapesDanglingLinksAndHardLinks() throws {
        let root = try temporaryDirectory(), outside = try temporaryDirectory()
        let paths = try SteamPreparationPaths(root: root)
        let parent = root.appendingPathComponent("engine")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        XCTAssertThrowsError(try paths.check(parent.appendingPathComponent("bin/settings/options.ini")))
        XCTAssertThrowsError(try paths.check(parent.appendingPathComponent("../apparently-contained.ini")))
        XCTAssertThrowsError(try paths.check(root.appendingPathComponent("../escape")))
        let dangling = root.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "absent")
        XCTAssertThrowsError(try paths.check(dangling))
        let original = outside.appendingPathComponent("original"), link = root.appendingPathComponent("hardlink")
        try Data("keep".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: link)
        XCTAssertThrowsError(try paths.check(link))
        XCTAssertNoThrow(try paths.check(root.appendingPathComponent("new/parents/settings.ini")))
    }

    func testRootAndAncestorReplacementInvalidatesExistingGuard() throws {
        let storage = try temporaryDirectory(), root = storage.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = try SteamPreparationPaths(root: root)
        let moved = storage.appendingPathComponent("previous")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try paths.check(root.appendingPathComponent("file")))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        XCTAssertThrowsError(try SteamPreparationPaths(root: root))
    }

    func testStandardMacTemporaryAliasIsValidStorage() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("SteamPreparation-" + UUID().uuidString)
        try SteamPreparationPaths.checkStorageDirectory(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try SteamPreparationPaths(root: root)
        XCTAssertNoThrow(try paths.check(root.appendingPathComponent("settings/config.ini")))
        let external = root.appendingPathComponent("external")
        try FileManager.default.createSymbolicLink(atPath: external.path, withDestinationPath: "/tmp")
        XCTAssertThrowsError(try SteamPreparationPaths.checkStorageDirectory(external.appendingPathComponent("save")))
    }
}
