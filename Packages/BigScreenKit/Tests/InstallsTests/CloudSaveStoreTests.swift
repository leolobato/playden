import XCTest
import Foundation
import Darwin
import CryptoKit
import Domain
import Runner
@testable import Installs

final class CloudSaveStoreTests: XCTestCase {
    private let gameID = GameID(source: "steam", value: "1055540")
    private let mapping = SaveMapping(rules: [.init(root: .game, directory: "saves", pattern: "*.mountain", recursive: true,
                                                   cloudPrefix: "%GameInstall%saves")], coverage: .metadata)
    private func directory() throws -> URL {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("CloudSaveFiles-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func put(_ text: String, _ path: String, at root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    private func read(_ path: String, at root: URL) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    private func upload(_ text: String, name: String = "GameSaveNew.mountain") -> CloudUpload {
        let data = Data(text.utf8)
        return .init(file: .init(name: "%GameInstall%saves/" + name, sha1: Data(Insecure.SHA1.hash(data: data)),
            bytes: Int64(data.count), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)), data: data)
    }
    private func remote(_ uploads: [CloudUpload], account: String = "account-a", revision: UInt64 = 4) -> CloudFileList {
        .init(gameID: gameID, accountKey: account, revision: revision, files: uploads.map(\.file))
    }
    private func plan(_ local: SaveSnapshot, remote: CloudFileList, baseline: CloudSyncBaseline? = nil) throws -> CloudSyncPlan {
        try CloudSyncPlanner.plan(installationID: local.installationID, mapping: local.mapping,
            localFiles: local.files.map { .init(location: .init(root: $0.root, path: $0.path), sha1: $0.sha1, bytes: $0.bytes, modifiedAt: $0.modifiedAt) },
            remote: remote, baseline: baseline, attachedAccountKey: remote.accountKey)
    }
    private func base(_ local: SaveSnapshot, remote: CloudFileList) -> CloudSyncBaseline {
        .init(gameID: gameID, installationID: local.installationID, accountKey: remote.accountKey,
              revision: remote.revision, mapping: local.mapping, files: remote.files)
    }
    private func archive(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent(CrossOverGameBottles.name(for: gameID)).appendingPathComponent(id.uuidString)
    }

    func testDownloadToEmptyInstallPreservesMetadataBackupsAndRestartIdempotence() async throws {
        let root = try directory(), game = try directory(), store = SaveStore(root: root), installationID = UUID()
        let local = try await store.snapshot(gameID: gameID, installationID: installationID, mapping: mapping, roots: [.game: game])
        let payloads = [upload("remote progress")], list = remote(payloads)
        let downloaded = try await store.stageCloud(list, installationID: installationID, mapping: mapping, downloads: payloads)
        let review = try plan(local, remote: list)
        XCTAssertEqual(review.decisions.first?.action, .download)
        let result = try await store.applyCloud(review, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game])
        XCTAssertEqual(result.first?.sha1, payloads[0].file.sha1)
        XCTAssertEqual(try read("saves/GameSaveNew.mountain", at: game), "remote progress")
        XCTAssertEqual(result.first?.modifiedAt, payloads[0].file.modifiedAt)
        let restarted = SaveStore(root: root)
        _ = try await restarted.applyCloud(review, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game])
        let reused = try await restarted.stageCloud(list, installationID: installationID, mapping: mapping, downloads: payloads, id: downloaded.id)
        XCTAssertEqual(reused, downloaded)
        let copy = try await restarted.stagedContents(downloaded.id, gameID: gameID, location: .init(root: .game, path: "saves/GameSaveNew.mountain"))
        XCTAssertEqual(copy, payloads[0].data)
        let localAgain = try await restarted.verified(local.id, gameID: gameID)
        XCTAssertTrue(localAgain.files.isEmpty)
    }

    func testAtomicReplacementAndDeletionKeepOriginalsAndIgnoreUnmappedBackup() async throws {
        let root = try directory(), game = try directory(), store = SaveStore(root: root), installationID = UUID()
        try put("old progress", "saves/GameSaveNew.MOUNTAIN", at: game)
        try put("old slot", "saves/slot.mountain", at: game)
        try put("unmapped backup", "saves/GameSaveNew.mountain_backup", at: game)
        let local = try await store.snapshot(gameID: gameID, installationID: installationID, mapping: mapping, roots: [.game: game])
        let old = remote([upload("old progress"), upload("old slot", name: "slot.mountain")])
        let payloads = [upload("updated remote progress")], current = remote(payloads, revision: 5)
        let downloaded = try await store.stageCloud(current, installationID: installationID, mapping: mapping, downloads: payloads)
        let review = try plan(local, remote: current, baseline: base(local, remote: old))
        XCTAssertEqual(Set(review.decisions.map(\.action)), [.download, .deleteLocal])
        _ = try await store.applyCloud(review, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game])
        XCTAssertEqual(try read("saves/GameSaveNew.MOUNTAIN", at: game), "updated remote progress")
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent("saves/slot.mountain").path))
        XCTAssertEqual(try read("saves/GameSaveNew.mountain_backup", at: game), "unmapped backup")
        let saved = try await store.stagedContents(local.id, gameID: gameID, location: .init(root: .game, path: "saves/GameSaveNew.MOUNTAIN"))
        XCTAssertEqual(String(decoding: saved, as: UTF8.self), "old progress")
        _ = try await store.applyCloud(review, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: game.appendingPathComponent("saves").path).sorted(),
                       ["GameSaveNew.MOUNTAIN", "GameSaveNew.mountain_backup"])
    }

    func testInterruptionBetweenFilesResumesFromMixedOldAndNewContent() async throws {
        let root = try directory(), game = try directory(), store = SaveStore(root: root), installationID = UUID()
        try put("old a", "saves/a.mountain", at: game); try put("old z", "saves/z.mountain", at: game)
        let local = try await store.snapshot(gameID: gameID, installationID: installationID, mapping: mapping, roots: [.game: game])
        let old = remote([upload("old a", name: "a.mountain"), upload("old z", name: "z.mountain")])
        let payloads = [upload("new a", name: "a.mountain"), upload("new z", name: "z.mountain")], current = remote(payloads, revision: 5)
        let downloaded = try await store.stageCloud(current, installationID: installationID, mapping: mapping, downloads: payloads)
        let review = try plan(local, remote: current, baseline: base(local, remote: old))
        do {
            _ = try await store.applyCloud(review, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game]) { count, _ in
                if count == 1 { throw CancellationError() }
            }
            XCTFail("Expected interruption")
        } catch is CancellationError {}
        XCTAssertEqual(try read("saves/a.mountain", at: game), "new a")
        XCTAssertEqual(try read("saves/z.mountain", at: game), "old z")
        let restarted = SaveStore(root: root)
        _ = try await restarted.applyCloud(review, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game])
        XCTAssertEqual(try read("saves/z.mountain", at: game), "new z")
        let verified = try await restarted.verified(local.id, gameID: gameID)
        XCTAssertEqual(verified, local)
    }

    func testChangedProgressAndNewFilesPreflightBeforeAnyReplacement() async throws {
        for addFile in [false, true] {
            let root = try directory(), game = try directory(), store = SaveStore(root: root), installationID = UUID()
            try put("old a", "saves/a.mountain", at: game); try put("old z", "saves/z.mountain", at: game)
            let local = try await store.snapshot(gameID: gameID, installationID: installationID, mapping: mapping, roots: [.game: game])
            let old = remote([upload("old a", name: "a.mountain"), upload("old z", name: "z.mountain")])
            let payloads = [upload("new a", name: "a.mountain"), upload("new z", name: "z.mountain")], current = remote(payloads, revision: 5)
            let downloaded = try await store.stageCloud(current, installationID: installationID, mapping: mapping, downloads: payloads)
            let review = try plan(local, remote: current, baseline: base(local, remote: old))
            try put("unreviewed progress", addFile ? "saves/extra.mountain" : "saves/z.mountain", at: game)
            do {
                _ = try await store.applyCloud(review, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game])
                XCTFail("Applied a stale review")
            } catch {}
            XCTAssertEqual(try read("saves/a.mountain", at: game), "old a")
            XCTAssertEqual(try read(addFile ? "saves/extra.mountain" : "saves/z.mountain", at: game), "unreviewed progress")
        }
    }

    func testConflictsCorruptCopiesAndAccountMismatchNeverApply() async throws {
        let root = try directory(), game = try directory(), store = SaveStore(root: root), installationID = UUID()
        try put("local", "saves/GameSaveNew.mountain", at: game)
        let local = try await store.snapshot(gameID: gameID, installationID: installationID, mapping: mapping, roots: [.game: game])
        let payloads = [upload("remote")], current = remote(payloads)
        let downloaded = try await store.stageCloud(current, installationID: installationID, mapping: mapping, downloads: payloads)
        let conflict = try plan(local, remote: current)
        XCTAssertTrue(conflict.hasConflicts)
        do { _ = try await store.applyCloud(conflict, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game]); XCTFail() } catch {}
        let valid = try plan(local, remote: current, baseline: base(local, remote: remote([upload("local")], revision: 3)))
        let other = try await store.stageCloud(remote(payloads, account: "b"), installationID: installationID, mapping: mapping, downloads: payloads)
        do { _ = try await store.applyCloud(valid, localSnapshotID: local.id, remoteSnapshotID: other.id, roots: [.game: game]); XCTFail() } catch {}
        try Data("damaged".utf8).write(to: archive(root, downloaded.id).appendingPathComponent("files/0"))
        do { _ = try await store.applyCloud(valid, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game]); XCTFail() } catch {}
        XCTAssertEqual(try read("saves/GameSaveNew.mountain", at: game), "local")
    }

    func testRemotePayloadsAndMappingsMustBeCompleteBeforePublication() async throws {
        let root = try directory(), store = SaveStore(root: root), installationID = UUID(), payload = upload("remote")
        for kind in ["missing", "hash", "duplicate", "traversal", "unknown", "reserved"] {
            var list = remote([payload]), payloads = [payload]
            switch kind {
            case "missing": payloads = []
            case "hash": payloads = [.init(file: payload.file, data: Data("wrong!".utf8))]
            case "duplicate": list = remote([payload, payload])
            case "traversal": payloads = [upload("bad", name: "../private.mountain")]; list = remote(payloads)
            case "unknown": payloads = [upload("bad", name: "not-a-save.txt")]; list = remote(payloads)
            default: payloads = [upload("bad", name: ".bigscreen-cloud-\(UUID()).tmp/file.mountain")]; list = remote(payloads)
            }
            let id = UUID()
            do { _ = try await store.stageCloud(list, installationID: installationID, mapping: mapping, downloads: payloads, id: id); XCTFail("Accepted \(kind)") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: archive(root, id).path))
        }
    }

    func testDestinationLinksAndHardlinksCannotRedirectReplacement() async throws {
        for kind in ["file", "parent", "hardlink"] {
            let root = try directory(), game = try directory(), outside = try directory(), store = SaveStore(root: root), installationID = UUID()
            let local = try await store.snapshot(gameID: gameID, installationID: installationID, mapping: mapping, roots: [.game: game])
            let payloads = [upload("remote")], current = remote(payloads)
            let downloaded = try await store.stageCloud(current, installationID: installationID, mapping: mapping, downloads: payloads)
            let review = try plan(local, remote: current)
            try put("unrelated", "GameSaveNew.mountain", at: outside)
            if kind == "parent" {
                try FileManager.default.createSymbolicLink(at: game.appendingPathComponent("saves"), withDestinationURL: outside)
            } else {
                try FileManager.default.createDirectory(at: game.appendingPathComponent("saves"), withIntermediateDirectories: true)
                let target = game.appendingPathComponent("saves/GameSaveNew.mountain"), original = outside.appendingPathComponent("GameSaveNew.mountain")
                if kind == "file" { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original) }
                else { try FileManager.default.linkItem(at: original, to: target) }
            }
            do { _ = try await store.applyCloud(review, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game]); XCTFail("Followed \(kind)") } catch {}
            XCTAssertEqual(try read("GameSaveNew.mountain", at: outside), "unrelated")
        }
    }

    func testPrimitiveRecoversPublishedReplacementAndRemovalTemporaries() throws {
        let root = try directory(), directory = try SaveDirectory(url: root)
        try put("old", "save", at: root)
        let old = try XCTUnwrap(directory.file("save")?.stream())
        try put("new", "new", at: root)
        let new = try XCTUnwrap(directory.file("new")?.stream())
        let temp = ".bigscreen-cloud-\(UUID()).tmp"
        // A fully staged replacement can be reused after interruption before the exchange.
        try put("new", temp, at: root)
        try directory.changeCloudFile("save", expected: old, desired: new, temporary: temp) { _ in XCTFail("Recopied verified staging") }
        XCTAssertEqual(try read("save", at: root), "new")
        // State after an atomic exchange and before deleting the old temporary file.
        try put("new", "save", at: root); try put("old", temp, at: root)
        try directory.changeCloudFile("save", expected: old, desired: new, temporary: temp) { _ in XCTFail("Rewrote a published save") }
        XCTAssertNil(try directory.info(temp))
        XCTAssertEqual(try read("save", at: root), "new")
        // State after moving a deleted save aside and before unlinking its temporary file.
        try FileManager.default.removeItem(at: root.appendingPathComponent("save"))
        try put("old", temp, at: root)
        try directory.changeCloudFile("save", expected: old, desired: nil, temporary: temp) { _ in XCTFail() }
        XCTAssertNil(try directory.info(temp))
        // An unrecognized third copy cannot be erased during recovery.
        try put("new", "save", at: root); try put("unexpected", temp, at: root)
        XCTAssertThrowsError(try directory.changeCloudFile("save", expected: old, desired: new, temporary: temp) { _ in XCTFail() })
        XCTAssertEqual(try read(temp, at: root), "unexpected")
    }

    func testReservedScratchFilesAreNotPlayerSavesForWildcardMappings() async throws {
        let root = try directory(), game = try directory(), store = SaveStore(root: root)
        let mapping = SaveMapping(rules: [.init(root: .game, directory: "saves", cloudPrefix: "%GameInstall%saves")], coverage: .metadata)
        try put("player", "saves/progress", at: game)
        try put("partial", "saves/.bigscreen-save-\(UUID()).tmp", at: game)
        try put("old", "saves/.bigscreen-cloud-\(UUID()).tmp", at: game)
        let snapshot = try await store.snapshot(gameID: gameID, installationID: UUID(), mapping: mapping, roots: [.game: game])
        XCTAssertEqual(snapshot.files.map(\.path), ["saves/progress"])
    }
}
