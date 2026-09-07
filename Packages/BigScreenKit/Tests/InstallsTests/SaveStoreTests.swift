import XCTest
import Foundation
import Darwin
import Domain
import Runner
@testable import Installs

final class SaveStoreTests: XCTestCase {
    private let game = GameID(source: "fixture", value: "save-game")
    private func directory() throws -> URL {
        // Foundation preserves macOS's /var alias even in resolvingSymlinksInPath(). The
        // store intentionally requires physical roots, so obtain the physical temp parent.
        let resolved = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("BigScreen-saves-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func put(_ bytes: String, _ path: String, at root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: file)
    }
    private var mapping: SaveMapping {
        .init(rules: [.init(root: .bottle, directory: "LocalLow/adamgryu/A Short Hike", pattern: "*.mountain", recursive: false),
                      .init(root: .game, directory: "saves", pattern: "*.sav")], coverage: .metadata)
    }
    func testRetainRestoreRestartAndIdempotenceWithBothRoots() async throws {
        let root = try directory(), gameRoot = try directory(), bottle = try directory(), restoredGame = try directory(), restoredBottle = try directory()
        try put("progress", "LocalLow/adamgryu/A Short Hike/GameSaveNew.MOUNTAIN", at: bottle)
        try put("log only", "LocalLow/adamgryu/A Short Hike/Player.log", at: bottle)
        try put("not recursive", "LocalLow/adamgryu/A Short Hike/old/backup.mountain", at: bottle)
        try put("slot 2", "saves/nested/player.sav", at: gameRoot)
        let store = SaveStore(root: root), installation = UUID(), id = UUID()
        let snapshot = try await store.snapshot(gameID: game, installationID: installation, mapping: mapping, roots: [.game: gameRoot, .bottle: bottle], id: id)
        XCTAssertEqual(snapshot.files.count, 2)
        XCTAssertEqual(snapshot.retainedBytes, 14)
        XCTAssertFalse(snapshot.mapping.permitsRemovingUnmappedFiles)
        let restarted = SaveStore(root: root)
        let same = try await restarted.snapshot(gameID: game, installationID: installation, mapping: mapping, roots: [.game: gameRoot, .bottle: bottle], id: id)
        XCTAssertEqual(same, snapshot)
        _ = try await restarted.restore(id, gameID: game, roots: [.game: restoredGame, .bottle: restoredBottle])
        _ = try await restarted.restore(id, gameID: game, roots: [.game: restoredGame, .bottle: restoredBottle])
        XCTAssertEqual(try String(contentsOf: restoredGame.appendingPathComponent("saves/nested/player.sav"), encoding: .utf8), "slot 2")
        XCTAssertEqual(try String(contentsOf: restoredBottle.appendingPathComponent("LocalLow/adamgryu/A Short Hike/GameSaveNew.MOUNTAIN"), encoding: .utf8), "progress")
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredBottle.appendingPathComponent("LocalLow/adamgryu/A Short Hike/Player.log").path))
        let verified = try await restarted.verified(id, gameID: game)
        XCTAssertEqual(verified, snapshot, "Restoring must not consume the retained copy")
        var info = stat()
        XCTAssertEqual(lstat(restoredGame.appendingPathComponent("saves/nested/player.sav").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }
    func testConflictsPreflightAllFilesAndNeverUseNewestTimestamp() async throws {
        let root = try directory(), source = try directory(), destination = try directory()
        let mapping = SaveMapping(rules: [.init(root: .game, directory: "saves")])
        try put("first", "saves/a.sav", at: source)
        try put("second", "saves/z.sav", at: source)
        try put("different local progress", "saves/z.sav", at: destination)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: destination.appendingPathComponent("saves/z.sav").path)
        let store = SaveStore(root: root)
        let snapshot = try await store.snapshot(gameID: game, installationID: UUID(), mapping: mapping, roots: [.game: source])
        do { _ = try await store.restore(snapshot.id, gameID: game, roots: [.game: destination]); XCTFail("Overwrote conflicting progress") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("saves/a.sav").path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("saves/z.sav"), encoding: .utf8), "different local progress")
    }
    func testCorruptArchiveBlocksEveryRestoreAndUnpublishedCopiesAreNotBackups() async throws {
        let root = try directory(), source = try directory(), destination = try directory()
        try put("a", "saves/a", at: source); try put("z", "saves/z", at: source)
        let store = SaveStore(root: root), mapping = SaveMapping(rules: [.init(root: .game, directory: "saves")])
        let snapshot = try await store.snapshot(gameID: game, installationID: UUID(), mapping: mapping, roots: [.game: source])
        let archive = root.appendingPathComponent(CrossOverGameBottles.name(for: game)).appendingPathComponent(snapshot.id.uuidString)
        try Data("damaged".utf8).write(to: archive.appendingPathComponent("files/1"))
        do { _ = try await store.restore(snapshot.id, gameID: game, roots: [.game: destination]); XCTFail("Restored corrupt backup") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        let interruptedID = UUID()
        try FileManager.default.moveItem(at: archive, to: archive.deletingLastPathComponent().appendingPathComponent(".partial-\(interruptedID)"))
        do { _ = try await store.verified(interruptedID, gameID: game); XCTFail("Accepted unpublished backup") } catch {}
    }
    func testRejectsSourceAndDestinationLinksHardlinksAndTraversal() async throws {
        for kind in ["symlink", "hardlink", "parent-link", "traversal"] {
            let root = try directory(), source = try directory(), outside = try directory()
            try put("unrelated", "private.sav", at: outside)
            var rule = SaveRule(root: .game, directory: "saves")
            switch kind {
            case "symlink":
                try FileManager.default.createDirectory(at: source.appendingPathComponent("saves"), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("saves/data.sav"), withDestinationURL: outside.appendingPathComponent("private.sav"))
            case "hardlink":
                try FileManager.default.createDirectory(at: source.appendingPathComponent("saves"), withIntermediateDirectories: true)
                try FileManager.default.linkItem(at: outside.appendingPathComponent("private.sav"), to: source.appendingPathComponent("saves/data.sav"))
            case "parent-link": try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("saves"), withDestinationURL: outside)
            default: rule = .init(root: .game, directory: "../outside")
            }
            do {
                _ = try await SaveStore(root: root).snapshot(gameID: game, installationID: UUID(), mapping: .init(rules: [rule]), roots: [.game: source])
                XCTFail("Accepted \(kind)")
            } catch {}
            XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("private.sav"), encoding: .utf8), "unrelated")
        }
        let root = try directory(), source = try directory(), destination = try directory(), outside = try directory()
        try put("save", "saves/player.sav", at: source)
        let store = SaveStore(root: root)
        let snapshot = try await store.snapshot(gameID: game, installationID: UUID(), mapping: .init(rules: [.init(root: .game, directory: "saves")]), roots: [.game: source])
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("saves"), withDestinationURL: outside)
        do { _ = try await store.restore(snapshot.id, gameID: game, roots: [.game: destination]); XCTFail("Followed destination link") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testMissingFilesDoNotInventSavesAndOverlappingRulesDeduplicate() async throws {
        let source = try directory(), root = try directory(), store = SaveStore(root: root)
        let mapping = SaveMapping(rules: [.init(root: .game, directory: "saves"), .init(root: .game, directory: "saves/nested"), .init(root: .game, directory: "absent")])
        let empty = try await store.snapshot(gameID: game, installationID: UUID(), mapping: mapping, roots: [.game: source])
        XCTAssertTrue(empty.files.isEmpty)
        XCTAssertFalse(empty.mapping.permitsRemovingUnmappedFiles)
        try put("save", "saves/nested/slot.sav", at: source)
        let populated = try await store.snapshot(gameID: game, installationID: UUID(), mapping: mapping, roots: [.game: source])
        XCTAssertEqual(populated.files.count, 1)
    }
}
