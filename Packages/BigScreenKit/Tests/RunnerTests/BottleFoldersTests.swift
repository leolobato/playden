import XCTest
import Domain
@testable import Runner

final class BottleFoldersTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BigScreen-folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func bottle(_ root: URL) throws -> URL {
        let bottle = root.appendingPathComponent("bottle")
        try FileManager.default.createDirectory(at: bottle.appendingPathComponent("drive_c/users/crossover/Desktop"), withIntermediateDirectories: true)
        try "[Bottle]\n\"Description\" = \"Fixture\"\n[EnvironmentVariables]\n\"WINEMSYNC\" = \"1\"\n[Other]\nvalue=retained\n".write(to: bottle.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
        return bottle
    }
    func testReplacesHostLinksWithoutFollowingOrDeletingTheirContents() throws {
        let root = try root(), bottle = try bottle(root)
        let personal = root.appendingPathComponent("personal")
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        let saved = personal.appendingPathComponent("untouched.txt")
        try Data("personal data".utf8).write(to: saved)
        let profile = bottle.appendingPathComponent("drive_c/users/crossover")
        for path in ["Documents", "Videos", "Desktop/My Mac Desktop"] {
            try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent(path), withDestinationURL: personal)
        }
        let desktopFile = profile.appendingPathComponent("Desktop/game-save.dat")
        try Data("keep this too".utf8).write(to: desktopFile)
        try BottleFolders.configure(bottle)
        try BottleFolders.verify(bottle)
        XCTAssertEqual(try Data(contentsOf: saved), Data("personal data".utf8))
        XCTAssertEqual(try Data(contentsOf: desktopFile), Data("keep this too".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Documents").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Videos").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Desktop/My Mac Desktop").path))
        let config = try String(contentsOf: bottle.appendingPathComponent("cxbottle.conf"), encoding: .utf8)
        try BottleFolders.configure(bottle)
        XCTAssertEqual(try String(contentsOf: bottle.appendingPathComponent("cxbottle.conf"), encoding: .utf8), config)
        XCTAssertTrue(config.contains("value=retained"))
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("Videos"), withDestinationURL: personal)
        XCTAssertThrowsError(try BottleFolders.verify(bottle))
    }
    func testPublicationRewritesFolderTargetsToFinalBottle() throws {
        let root = try root(), bottle = try bottle(root), destination = root.appendingPathComponent("published")
        try BottleFolders.configure(bottle, publishedAt: destination)
        XCTAssertThrowsError(try BottleFolders.verify(bottle))
        try FileManager.default.moveItem(at: bottle, to: destination)
        try BottleFolders.verify(destination)
        let mapping = try String(contentsOf: destination.appendingPathComponent(".bigscreen-folders/user-dirs.dirs"), encoding: .utf8)
        XCTAssertTrue(mapping.contains(destination.path))
        XCTAssertFalse(mapping.contains(bottle.path + "/"))
    }
    func testLinkedProfileAndConfigurationAreRefused() throws {
        let root = try root(), bottle = try bottle(root)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bottle.appendingPathComponent(".bigscreen-folders"), withDestinationURL: outside)
        XCTAssertThrowsError(try BottleFolders.configure(bottle))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: bottle.appendingPathComponent(".bigscreen-folders"))
        let config = bottle.appendingPathComponent("cxbottle.conf")
        let original = outside.appendingPathComponent("original.conf")
        try FileManager.default.moveItem(at: config, to: original)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: original)
        let before = try Data(contentsOf: original)
        XCTAssertThrowsError(try BottleFolders.configure(bottle))
        XCTAssertEqual(try Data(contentsOf: original), before)
    }
}
