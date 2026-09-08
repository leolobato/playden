import XCTest
import Foundation
import Darwin
import CryptoKit
import Domain
import Catalog
@testable import Installs

private actor CloudServer: CloudReading, CloudWriting {
    let gameID: GameID
    var accountKey = "account-a", revision: UInt64 = 1
    var contents: [String: CloudUpload] = [:]
    var offline = false, failAfterCommit = false
    var uploadCalls = 0, batchObserved = false
    let catalog: CatalogStore
    init(gameID: GameID, catalog: CatalogStore) { self.gameID = gameID; self.catalog = catalog }
    func replace(_ files: [CloudUpload], account: String? = nil) {
        contents = Dictionary(uniqueKeysWithValues: files.map { ($0.file.name, $0) }); revision += 1
        if let account { accountKey = account }
    }
    func setOffline(_ value: Bool) { offline = value }
    func failNextCommitResponse() { failAfterCommit = true }
    func files(for gameID: GameID) throws -> CloudFileList {
        if offline { throw SourceFailure.network }
        return .init(gameID: gameID, accountKey: accountKey, revision: revision,
                     files: contents.values.map(\.file).sorted { $0.name < $1.name })
    }
    func download(_ file: CloudFile, from list: CloudFileList) throws -> Data {
        guard try files(for: list.gameID) == list, let data = contents[file.name]?.data else { throw SourceFailure.network }
        return data
    }
    func upload(_ files: [CloudUpload], deleting: [String], basedOn: CloudFileList, clientID: UInt64,
                buildID: UInt64, onBatchStarted: @escaping @Sendable (CloudUploadBatch) async throws -> Void) async throws -> CloudFileList {
        guard try self.files(for: gameID) == basedOn else { throw SourceFailure.network }
        uploadCalls += 1
        let batch = CloudUploadBatch(id: UInt64(uploadCalls), revision: revision + 1)
        try await onBatchStarted(batch)
        batchObserved = try catalog.cloudOperations(for: gameID).contains { $0.claim != nil && $0.batches.contains(batch) }
        guard batchObserved else { throw SourceFailure.storage("Missing batch receipt") }
        for file in files { contents[file.file.name] = file }
        for name in deleting { contents[name] = nil }
        revision += 1
        if failAfterCommit { failAfterCommit = false; throw SourceFailure.network }
        return try self.files(for: gameID)
    }
}

private actor ReplacingRecoveredRoot {
    let store: CatalogStore, game: URL, moved: URL
    let afterRecovery: Bool
    var replaced = false
    var reads = 0
    init(store: CatalogStore, game: URL, moved: URL, afterRecovery: Bool = true) {
        self.store = store; self.game = game; self.moved = moved; self.afterRecovery = afterRecovery
    }
    func roots() throws -> [SaveRoot: URL] {
        reads += 1
        if !replaced, let pending = try store.cloudOperations().last(where: { !$0.phase.isTerminal }),
           afterRecovery ? (pending.archiveRecoveryInput != nil && !pending.needsLocalRecovery &&
               pending.localRecoveries?.last?.appliedPlan != nil) : reads == 2 {
            try FileManager.default.moveItem(at: game, to: moved)
            try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            replaced = true
        }
        return [.game: game]
    }
}

final class CloudSyncServiceTests: XCTestCase {
    private let gameID = GameID(source: "steam", value: "1055540")
    private let mapping = SaveMapping(rules: [.init(root: .game, directory: "saves", pattern: "*.mountain", cloudPrefix: "%GameInstall%saves")], coverage: .metadata)
    private func directory() throws -> URL {
        let pointer = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent("CloudSyncService-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func installed(_ root: URL) -> InstallationRecord {
        .init(game: .init(id: gameID, title: "A Short Hike"),
            location: .init(volumeID: "fixture", lastKnownRoot: root, relativePath: "game"), bottleID: "gn-steam-1055540",
            manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "ShortHike.exe"), installedBytes: 100)
    }
    private func payload(_ text: String, name: String = "GameSaveNew.mountain") -> CloudUpload {
        let data = Data(text.utf8)
        return .init(file: .init(name: "%GameInstall%saves/" + name, sha1: Data(Insecure.SHA1.hash(data: data)),
            bytes: Int64(data.count), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)), data: data)
    }
    private func put(_ text: String, at root: URL, name: String = "GameSaveNew.mountain") throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("saves"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: root.appendingPathComponent("saves/" + name))
    }
    private func read(_ root: URL, name: String = "GameSaveNew.mountain") throws -> String {
        try String(contentsOf: root.appendingPathComponent("saves/" + name), encoding: .utf8)
    }
    private func service(_ store: CatalogStore, server: CloudServer, saves: SaveStore, root: URL,
                         validate: @escaping CloudSyncService.UploadValidation = { _, _, _ in }) -> CloudSyncService {
        CloudSyncService(catalog: store, saves: saves, reader: server, writer: server, roots: { _ in [.game: root] }, validateUploads: validate)
    }

    func testPullEditPushAndReopenUseRealJournalAndFilesystem() async throws {
        let root = try directory(), game = try directory(), store = try CatalogStore(path: root.appendingPathComponent("catalog.sqlite").path)
        let installed = installed(game), saves = SaveStore(root: root.appendingPathComponent("backups"))
        try store.saveInstallation(installed)
        let server = CloudServer(gameID: gameID, catalog: store), cloud = service(store, server: server, saves: saves, root: game)
        await server.replace([payload("remote progress")])
        let pulled = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(pulled.state, .upToDate, pulled.message)
        XCTAssertEqual(try read(game), "remote progress")
        XCTAssertEqual(try store.cloudAttachment(for: gameID, installationID: installed.id)?.accountKey, "account-a")
        let oldRevision = try XCTUnwrap(store.cloudBaseline(for: gameID, accountKey: "account-a")?.revision)
        try put("more local progress", at: game)
        let pushed = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(pushed.state, .upToDate, pushed.message)
        let remote = try await server.files(for: gameID)
        XCTAssertEqual(remote.files.first?.sha1, payload("more local progress").file.sha1)
        XCTAssertEqual(remote.revision, oldRevision + 1)
        let observed = await server.batchObserved; XCTAssertTrue(observed)
        let reopened = try CatalogStore(path: root.appendingPathComponent("catalog.sqlite").path)
        XCTAssertEqual(try reopened.cloudBaseline(for: gameID, accountKey: "account-a")?.files, remote.files)
        XCTAssertTrue(try reopened.cloudOperations().allSatisfy { $0.phase.isTerminal })
        XCTAssertEqual(try reopened.cloudClientID(), try store.cloudClientID())
        XCTAssertEqual(try read(game), "more local progress")
    }

    func testRecreatedBottleRestoresCloudWithSameInstallationAfterRestart() async throws {
        let root = try directory(), bottle = root.appendingPathComponent("bottle")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("catalog.sqlite").path
        let store = try CatalogStore(path: database), installed = installed(bottle)
        let saves = SaveStore(root: root.appendingPathComponent("backups"))
        let mapping = SaveMapping(rules: [.init(root: .bottle, directory: "saves", pattern: "*.mountain",
            cloudPrefix: "%GameInstall%saves")], coverage: .metadata)
        try store.saveInstallation(installed)
        let server = CloudServer(gameID: gameID, catalog: store)
        let cloud = CloudSyncService(catalog: store, saves: saves, reader: server, writer: server,
            roots: { _ in [.bottle: bottle] }, validateUploads: { _, _, _ in })
        await server.replace([payload("preserved Cloud progress")])
        let initial = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(initial.state, .upToDate, initial.message)
        let remoteBefore = try await server.files(for: gameID)

        // Simulate losing the owned bottle and recreating it, then crashing before the app
        // can record recovery. Installation ID, path, owner and Cloud baseline are unchanged.
        let original = root.appendingPathComponent("original-bottle")
        try FileManager.default.moveItem(at: bottle, to: original)
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        let reopened = try CatalogStore(path: database)
        let restarted = CloudSyncService(catalog: reopened, saves: saves, reader: server, writer: server,
            roots: { _ in [.bottle: bottle] }, validateUploads: { _, _, _ in })
        let restored = await restarted.synchronize(installed, mapping: mapping)
        XCTAssertEqual(restored.state, .upToDate, restored.message)
        XCTAssertEqual(try read(bottle), "preserved Cloud progress")
        XCTAssertEqual(try read(original), "preserved Cloud progress")
        let remoteAfter = try await server.files(for: gameID), calls = await server.uploadCalls
        XCTAssertEqual(remoteAfter, remoteBefore)
        XCTAssertEqual(calls, 0, "A replacement bottle must never authorize remote deletion")
        XCTAssertEqual(try reopened.snapshot().entries.first?.installation?.id, installed.id)
    }

    func testConflictRequiresExactConsentAndRetainsBothCopies() async throws {
        let root = try directory(), game = try directory(), store = try CatalogStore(), installed = installed(game)
        let saves = SaveStore(root: root); try store.saveInstallation(installed); try put("local progress", at: game)
        let server = CloudServer(gameID: gameID, catalog: store), cloud = service(store, server: server, saves: saves, root: game)
        await server.replace([payload("different Cloud progress")])
        let conflict = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(conflict.state, .conflict, conflict.message); XCTAssertTrue(conflict.canPlayOffline)
        let reviewed = try XCTUnwrap(conflict.operation), localID = try XCTUnwrap(reviewed.localSnapshotID), remoteID = try XCTUnwrap(reviewed.remoteSnapshotID)
        XCTAssertEqual(try read(game), "local progress")
        let calls = await server.uploadCalls; XCTAssertEqual(calls, 0)
        let finished = await cloud.synchronize(installed, mapping: mapping,
            authorization: .init(operation: reviewed, conflictChoice: .remote, attachAccount: true))
        XCTAssertEqual(finished.state, .upToDate, finished.message)
        XCTAssertEqual(try read(game), "different Cloud progress")
        let location = CloudSavePath(root: .game, path: "saves/GameSaveNew.mountain")
        let oldLocal = try await saves.stagedContents(localID, gameID: gameID, location: location)
        let oldRemote = try await saves.stagedContents(remoteID, gameID: gameID, location: location)
        XCTAssertEqual(oldLocal, Data("local progress".utf8)); XCTAssertEqual(oldRemote, Data("different Cloud progress".utf8))
    }

    func testReplacingEmptyRootBeforeRemoteDeletionRejectsWriteThenRestoresOnRetry() async throws {
        let root = try directory(), game = root.appendingPathComponent("game"), store = try CatalogStore()
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let installed = installed(game), saves = SaveStore(root: root.appendingPathComponent("backups"))
        try store.saveInstallation(installed)
        let server = CloudServer(gameID: gameID, catalog: store)
        let cloud = service(store, server: server, saves: saves, root: game)
        await server.replace([payload("remote progress")])
        let initial = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(initial.state, .upToDate)
        try FileManager.default.removeItem(at: game.appendingPathComponent("saves/GameSaveNew.mountain"))
        let replacing = service(store, server: server, saves: saves, root: game) { _, uploads, deletes in
            XCTAssertTrue(uploads.isEmpty); XCTAssertEqual(deletes.count, 1)
            try FileManager.default.moveItem(at: game, to: root.appendingPathComponent("old-game"))
            try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        }
        let refused = await replacing.synchronize(installed, mapping: mapping)
        XCTAssertEqual(refused.state, .pendingUpload)
        XCTAssertTrue(refused.message.contains("save folder changed"), refused.message)
        let calls = await server.uploadCalls; XCTAssertEqual(calls, 0)
        let restored = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(restored.state, .upToDate, restored.message)
        XCTAssertEqual(try read(game), "remote progress")
        let finalCalls = await server.uploadCalls; XCTAssertEqual(finalCalls, 0)
    }

    func testReplacingRootWithIdenticalFilesInvalidatesExistingConflictConsent() async throws {
        let root = try directory(), game = root.appendingPathComponent("game"), store = try CatalogStore()
        let installed = installed(game), saves = SaveStore(root: root.appendingPathComponent("backups"))
        try store.saveInstallation(installed); try put("local", at: game)
        let server = CloudServer(gameID: gameID, catalog: store)
        let cloud = service(store, server: server, saves: saves, root: game)
        await server.replace([payload("remote")])
        let initial = await cloud.synchronize(installed, mapping: mapping)
        let reviewed = try XCTUnwrap(initial.operation)
        try FileManager.default.moveItem(at: game, to: root.appendingPathComponent("old-game"))
        try put("local", at: game)
        let result = await cloud.synchronize(installed, mapping: mapping,
            authorization: .init(operation: reviewed, conflictChoice: .local, attachAccount: true))
        XCTAssertEqual(result.state, .conflict, result.message)
        XCTAssertEqual(try read(game), "local")
        let calls = await server.uploadCalls; XCTAssertEqual(calls, 0)
        XCTAssertNil(try store.cloudAttachment(for: gameID, installationID: installed.id))
    }

    func testNetworkFailureStagesLatestProgressAndRetriesAfterOfflinePlay() async throws {
        let root = try directory(), game = try directory(), store = try CatalogStore(), installed = installed(game)
        let saves = SaveStore(root: root); try store.saveInstallation(installed)
        let server = CloudServer(gameID: gameID, catalog: store), cloud = service(store, server: server, saves: saves, root: game)
        await server.replace([payload("remote")]); _ = await cloud.synchronize(installed, mapping: mapping)
        await server.setOffline(true); try put("offline progress", at: game)
        let pending = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(pending.state, .pendingUpload); XCTAssertTrue(pending.canPlayOffline)
        XCTAssertNotNil(pending.operation?.localSnapshotID)
        let baseline = try store.cloudBaseline(for: gameID, accountKey: "account-a")
        try put("newer offline progress", at: game)
        let later = await cloud.synchronize(installed, mapping: mapping)
        let id = try XCTUnwrap(later.operation?.localSnapshotID)
        let saved = try await saves.stagedContents(id, gameID: gameID, location: .init(root: .game, path: "saves/GameSaveNew.mountain"))
        XCTAssertEqual(saved, Data("newer offline progress".utf8))
        XCTAssertEqual(try store.cloudBaseline(for: gameID, accountKey: "account-a"), baseline)
        await server.setOffline(false)
        let retried = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(retried.state, .upToDate, retried.message)
        let remote = try await server.files(for: gameID)
        XCTAssertEqual(remote.files.first?.sha1, payload("newer offline progress").file.sha1)
    }

    func testPendingUploadArchiveRestoresAfterRepeatedRootLossBeforeSteamIsAvailable() async throws {
        let root = try directory(), game = root.appendingPathComponent("game")
        let path = root.appendingPathComponent("catalog.sqlite").path, store = try CatalogStore(path: path)
        let installed = installed(game), saves = SaveStore(root: root.appendingPathComponent("backups"))
        try store.saveInstallation(installed); try put("unsynced progress", at: game)
        let server = CloudServer(gameID: gameID, catalog: store)
        await server.setOffline(true)
        let initial = await service(store, server: server, saves: saves, root: game).synchronize(installed, mapping: mapping)
        let archived = try XCTUnwrap(initial.operation)
        XCTAssertNil(archived.plan); XCTAssertNotNil(archived.localSnapshotID)
        let reopened = try CatalogStore(path: path)
        for attempt in 0..<2 {
            try FileManager.default.moveItem(at: game, to: root.appendingPathComponent("old-\(attempt)"))
            try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            let cloud = service(reopened, server: server, saves: saves, root: game)
            try await cloud.recoverInterruptedOperations()
            let result = await cloud.synchronize(installed, mapping: mapping)
            XCTAssertEqual(result.state, .pendingUpload, result.message); XCTAssertTrue(result.canPlayOffline)
            XCTAssertEqual(try read(game), "unsynced progress")
            XCTAssertNil(try reopened.cloudAttachment(for: gameID, installationID: installed.id))
            XCTAssertNil(try reopened.cloudBaseline(for: gameID, accountKey: "account-a"))
        }
        let history = try XCTUnwrap(reopened.cloudOperations().first { $0.id == archived.id })
        XCTAssertEqual(history.localSnapshotID, archived.localSnapshotID)
        XCTAssertNotNil(history.archiveRecoveryInput); XCTAssertEqual(history.phase, .superseded)
        await server.setOffline(false)
        let cloud = service(reopened, server: server, saves: saves, root: game)
        let review = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(review.state, .conflict); XCTAssertTrue(review.operation?.plan?.requiresAccountConfirmation == true)
        let before = await server.uploadCalls; XCTAssertEqual(before, 0)
        let confirmed = await cloud.synchronize(installed, mapping: mapping,
            authorization: .init(operation: try XCTUnwrap(review.operation), attachAccount: true))
        XCTAssertEqual(confirmed.state, .upToDate, confirmed.message)
        let uploaded = try await server.files(for: gameID)
        XCTAssertEqual(uploaded.files.first?.sha1, payload("unsynced progress").file.sha1)
    }

    func testLostPendingUploadWithNewProgressRequiresLocalOnlyWholeCopyChoice() async throws {
        for choice in [CloudSyncAuthorization.ConflictChoice.local, .remote] {
            let root = try directory(), game = root.appendingPathComponent("game"), store = try CatalogStore()
            let installed = installed(game), saves = SaveStore(root: root.appendingPathComponent("backups"))
            try store.saveInstallation(installed); try put("archived progress", at: game)
            try put("archived extra", at: game, name: "archived.mountain")
            let server = CloudServer(gameID: gameID, catalog: store); await server.setOffline(true)
            let cloud = service(store, server: server, saves: saves, root: game)
            _ = await cloud.synchronize(installed, mapping: mapping)
            try FileManager.default.moveItem(at: game, to: root.appendingPathComponent("old"))
            try put("new progress", at: game); try put("new extra", at: game, name: "new.mountain")
            let review = await cloud.synchronize(installed, mapping: mapping)
            XCTAssertEqual(review.state, .conflict, review.message); XCTAssertFalse(review.canPlayOffline)
            XCTAssertTrue(review.operation?.needsRecoveryReview == true)
            XCTAssertEqual(try read(game), "new progress")
            let result = await cloud.synchronize(installed, mapping: mapping,
                authorization: .init(operation: try XCTUnwrap(review.operation), conflictChoice: choice, attachAccount: true))
            XCTAssertEqual(result.state, .pendingUpload, result.message); XCTAssertTrue(result.canPlayOffline)
            XCTAssertEqual(try read(game), choice == .local ? "new progress" : "archived progress")
            XCTAssertEqual(FileManager.default.fileExists(atPath: game.appendingPathComponent("saves/new.mountain").path), choice == .local)
            XCTAssertEqual(FileManager.default.fileExists(atPath: game.appendingPathComponent("saves/archived.mountain").path), choice == .remote)
            XCTAssertNil(try store.cloudAttachment(for: gameID, installationID: installed.id))
            let calls = await server.uploadCalls; XCTAssertEqual(calls, 0)
        }
    }

    func testLostCommitResponseReconcilesRemoteWithoutUploadingTwice() async throws {
        let root = try directory(), game = try directory(), store = try CatalogStore(), installed = installed(game)
        let saves = SaveStore(root: root); try store.saveInstallation(installed)
        let server = CloudServer(gameID: gameID, catalog: store), cloud = service(store, server: server, saves: saves, root: game)
        await server.replace([payload("old")]); _ = await cloud.synchronize(installed, mapping: mapping)
        let baseline = try store.cloudBaseline(for: gameID, accountKey: "account-a")
        try put("new", at: game); await server.failNextCommitResponse()
        let interrupted = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(interrupted.state, .pendingUpload); XCTAssertEqual(interrupted.operation?.batches.count, 1)
        XCTAssertEqual(try store.cloudBaseline(for: gameID, accountKey: "account-a"), baseline)
        try FileManager.default.moveItem(at: game, to: root.appendingPathComponent("lost-runtime"))
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let restarted = service(store, server: server, saves: SaveStore(root: root), root: game)
        try await restarted.recoverInterruptedOperations()
        let reconciled = await restarted.synchronize(installed, mapping: mapping)
        XCTAssertEqual(reconciled.state, .upToDate, reconciled.message)
        XCTAssertEqual(try read(game), "new")
        let calls = await server.uploadCalls; XCTAssertEqual(calls, 1)
        XCTAssertTrue(try store.cloudOperations().contains { $0.id == interrupted.operation?.id && $0.batches.count == 1 })
    }

    func testRootLossBeforeFreshCheckpointKeepsRecoveryFenced() async throws {
        for afterRecovery in [false, true] {
            let root = try directory(), game = root.appendingPathComponent("game"), store = try CatalogStore()
            let installed = installed(game), saves = SaveStore(root: root.appendingPathComponent("backups"))
            try store.saveInstallation(installed); try put("only archived progress", at: game)
            let server = CloudServer(gameID: gameID, catalog: store); await server.setOffline(true)
            let first = await service(store, server: server, saves: saves, root: game).synchronize(installed, mapping: mapping)
            let original = try XCTUnwrap(first.operation)
            if afterRecovery {
                try FileManager.default.moveItem(at: game, to: root.appendingPathComponent("original"))
                try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            }
            let replacement = ReplacingRecoveredRoot(store: store, game: game,
                moved: root.appendingPathComponent("recovered"), afterRecovery: afterRecovery)
            let interrupted = CloudSyncService(catalog: store, saves: saves, reader: server, writer: server,
                roots: { _ in try await replacement.roots() }, validateUploads: { _, _, _ in })
            let result = await interrupted.synchronize(installed, mapping: mapping)
            XCTAssertFalse(result.canPlayOffline, result.message)
            XCTAssertTrue(result.operation?.needsLocalRecovery == true)
            XCTAssertEqual(result.operation?.id, original.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent("saves/GameSaveNew.mountain").path))
            let restarted = service(store, server: server, saves: saves, root: game)
            let restored = await restarted.synchronize(installed, mapping: mapping)
            XCTAssertTrue(restored.canPlayOffline, restored.message)
            XCTAssertEqual(try read(game), "only archived progress")
            XCTAssertNil(try store.cloudAttachment(for: gameID, installationID: installed.id))
        }
    }

    func testChangedRemoteOrLocalInvalidatesAConflictChoice() async throws {
        for changeRemote in [true, false] {
            let root = try directory(), game = try directory(), store = try CatalogStore(), installed = installed(game)
            let saves = SaveStore(root: root); try store.saveInstallation(installed); try put("local", at: game)
            let server = CloudServer(gameID: gameID, catalog: store), cloud = service(store, server: server, saves: saves, root: game)
            await server.replace([payload("remote")])
            let initial = await cloud.synchronize(installed, mapping: mapping)
            let reviewed = try XCTUnwrap(initial.operation)
            if changeRemote { await server.replace([payload("new remote")]) }
            else { try put("new local", at: game) }
            let result = await cloud.synchronize(installed, mapping: mapping,
                authorization: .init(operation: reviewed, conflictChoice: .local, attachAccount: true))
            XCTAssertEqual(result.state, .conflict, result.message)
            XCTAssertEqual(try read(game), changeRemote ? "local" : "new local")
            let calls = await server.uploadCalls; XCTAssertEqual(calls, 0)
            XCTAssertNil(try store.cloudAttachment(for: gameID, installationID: installed.id))
        }
    }

    func testAccountSwitchAndUploadValidationCannotSilentlyWrite() async throws {
        let root = try directory(), game = try directory(), store = try CatalogStore(), installed = installed(game)
        let saves = SaveStore(root: root); try store.saveInstallation(installed)
        let server = CloudServer(gameID: gameID, catalog: store), cloud = service(store, server: server, saves: saves, root: game)
        await server.replace([payload("account a progress")]); _ = await cloud.synchronize(installed, mapping: mapping)
        await server.replace([], account: "account-b")
        let switched = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(switched.state, .conflict); XCTAssertTrue(try XCTUnwrap(switched.operation?.plan).requiresAccountConfirmation)
        let refusing = service(store, server: server, saves: saves, root: game) { _, _, _ in
            throw OperationFailure(stage: "Validate saves", reason: "The game closed unexpectedly. These saves need validation.", output: "")
        }
        let result = await refusing.synchronize(installed, mapping: mapping,
            authorization: .init(operation: try XCTUnwrap(switched.operation), attachAccount: true))
        XCTAssertEqual(result.state, .pendingUpload); XCTAssertTrue(result.canPlayOffline)
        let calls = await server.uploadCalls; XCTAssertEqual(calls, 0)
        XCTAssertEqual(try read(game), "account a progress")
        XCTAssertNil(try store.cloudBaseline(for: gameID, accountKey: "account-b"))
    }

    func testInterruptedLocalApplicationFinishesOfflineBeforeAllowingPlay() async throws {
        let root = try directory(), game = try directory(), store = try CatalogStore(), installed = installed(game)
        let saves = SaveStore(root: root); try store.saveInstallation(installed)
        let server = CloudServer(gameID: gameID, catalog: store)
        let payloads = [payload("progress a", name: "a.mountain"), payload("progress z", name: "z.mountain")]
        await server.replace(payloads)
        let remote = try await server.files(for: gameID)
        let local = try await saves.snapshot(gameID: gameID, installationID: installed.id, mapping: mapping, roots: [.game: game])
        let downloaded = try await saves.stageCloud(remote, installationID: installed.id, mapping: mapping, downloads: payloads)
        let plan = try CloudSyncPlanner.plan(installationID: installed.id, mapping: mapping,
            localFiles: [], remote: remote, baseline: nil, attachedAccountKey: nil)
        var operation = try store.beginCloudSync(installation: installed, accountKey: remote.accountKey, mapping: mapping)
        operation = try store.stageCloudSync(operation, plan: plan, remote: remote,
            localSnapshotID: local.id, remoteSnapshotID: downloaded.id)
        operation = try store.markCloudApplying(operation)
        do {
            _ = try await saves.applyCloud(plan, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game]) { _, _ in
                throw SourceFailure.network
            }
            XCTFail("Expected interruption between files")
        } catch SourceFailure.network { }
        XCTAssertThrowsError(try store.saveSession(.init(gameID: gameID, bottleID: installed.bottleID)))
        await server.setOffline(true)
        let restarted = service(store, server: server, saves: SaveStore(root: root), root: game)
        try await restarted.recoverInterruptedOperations()
        let pending = await restarted.synchronize(installed, mapping: mapping)
        XCTAssertEqual(pending.state, .pendingUpload, pending.message)
        XCTAssertTrue(pending.canPlayOffline)
        XCTAssertEqual(try read(game, name: "a.mountain"), "progress a")
        XCTAssertEqual(try read(game, name: "z.mountain"), "progress z")
        XCTAssertNil(try store.cloudBaseline(for: gameID, accountKey: remote.accountKey))
        XCTAssertFalse(try XCTUnwrap(pending.operation).needsLocalRecovery)
        XCTAssertNoThrow(try store.saveSession(.init(gameID: gameID, bottleID: installed.bottleID)))
    }

    func testInterruptedPublicationRecoversIntoReplacementRootWhileOffline() async throws {
        let root = try directory(), game = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("catalog.sqlite").path
        let store = try CatalogStore(path: database), installed = installed(game)
        let saves = SaveStore(root: root.appendingPathComponent("backups")); try store.saveInstallation(installed)
        let server = CloudServer(gameID: gameID, catalog: store)
        let payloads = [payload("progress a", name: "a.mountain"), payload("progress z", name: "z.mountain")]
        await server.replace(payloads)
        let remote = try await server.files(for: gameID)
        let local = try await saves.snapshot(gameID: gameID, installationID: installed.id, mapping: mapping, roots: [.game: game])
        let downloaded = try await saves.stageCloud(remote, installationID: installed.id, mapping: mapping, downloads: payloads)
        let plan = try CloudSyncPlanner.plan(installationID: installed.id, mapping: mapping,
            localFiles: [], remote: remote, baseline: nil, attachedAccountKey: nil, rootIdentities: local.rootIdentities)
        var operation = try store.beginCloudSync(installation: installed, accountKey: remote.accountKey, mapping: mapping)
        operation = try store.stageCloudSync(operation, plan: plan, remote: remote,
            localSnapshotID: local.id, remoteSnapshotID: downloaded.id)
        operation = try store.markCloudApplying(operation)
        do {
            _ = try await saves.applyCloud(plan, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game]) { _, _ in
                throw SourceFailure.network
            }
            XCTFail("Expected interruption")
        } catch SourceFailure.network {}
        let original = root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: game, to: original)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        await server.setOffline(true)
        let reopened = try CatalogStore(path: database)
        let restarted = service(reopened, server: server, saves: saves, root: game)
        try await restarted.recoverInterruptedOperations()
        let recovered = await restarted.synchronize(installed, mapping: mapping)
        XCTAssertEqual(recovered.state, .pendingUpload, recovered.message)
        XCTAssertTrue(recovered.canPlayOffline, recovered.message)
        XCTAssertEqual(try read(game, name: "a.mountain"), "progress a")
        XCTAssertEqual(try read(game, name: "z.mountain"), "progress z")
        XCTAssertEqual(try read(original, name: "a.mountain"), "progress a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.appendingPathComponent("saves/z.mountain").path))
        XCTAssertNil(try reopened.cloudBaseline(for: gameID, accountKey: remote.accountKey))
        XCTAssertNoThrow(try reopened.saveSession(.init(gameID: gameID, bottleID: installed.bottleID)))
        let calls = await server.uploadCalls; XCTAssertEqual(calls, 0)
    }

    func testRemoteDeletionRequiresUploadValidationEvenWithoutUploadBytes() async throws {
        let root = try directory(), game = try directory(), store = try CatalogStore(), installed = installed(game)
        let saves = SaveStore(root: root); try store.saveInstallation(installed)
        let server = CloudServer(gameID: gameID, catalog: store), cloud = service(store, server: server, saves: saves, root: game)
        await server.replace([payload("progress")])
        let pulled = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(pulled.state, .upToDate)
        try FileManager.default.removeItem(at: game.appendingPathComponent("saves/GameSaveNew.mountain"))
        let refusing = service(store, server: server, saves: saves, root: game) { _, uploads, deleting in
            guard uploads.isEmpty else { throw SourceFailure.storage("Unexpected upload") }
            guard deleting.count == 1 else { throw SourceFailure.storage("Missing deletion review") }
            throw OperationFailure(stage: "Validate saves", reason: "Deletion needs validation", output: "")
        }
        let pending = await refusing.synchronize(installed, mapping: mapping)
        XCTAssertEqual(pending.state, .pendingUpload, pending.message)
        let retained = try await server.files(for: gameID)
        XCTAssertEqual(retained.files.count, 1)
        let calls = await server.uploadCalls; XCTAssertEqual(calls, 0)
        let finished = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertEqual(finished.state, .upToDate, finished.message)
        let deleted = try await server.files(for: gameID)
        XCTAssertTrue(deleted.files.isEmpty)
        XCTAssertEqual(try store.cloudBaseline(for: gameID, accountKey: "account-a")?.files, [])
    }

    private func mixedPublication() async throws -> (root: URL, game: URL, store: CatalogStore, installed: InstallationRecord,
                                                     saves: SaveStore, server: CloudServer, operation: CloudSyncOperation) {
        let root = try directory(), game = root.appendingPathComponent("game"), store = try CatalogStore()
        let installed = installed(game), saves = SaveStore(root: root.appendingPathComponent("backups"))
        try store.saveInstallation(installed)
        try put("local awaiting upload", at: game, name: "local.mountain")
        try put("old deleted save", at: game, name: "removed.mountain")
        let server = CloudServer(gameID: gameID, catalog: store)
        let payloads = [payload("recovered a", name: "a.mountain"), payload("recovered z", name: "z.mountain")]
        await server.replace(payloads)
        let remote = try await server.files(for: gameID)
        let local = try await saves.snapshot(gameID: gameID, installationID: installed.id, mapping: mapping, roots: [.game: game])
        let downloaded = try await saves.stageCloud(remote, installationID: installed.id, mapping: mapping, downloads: payloads)
        let paths = try CloudSavePaths(mapping: mapping)
        var decisions: [CloudSyncDecision] = try remote.files.map {
            .init(name: $0.name, location: try paths.localPath(for: $0.name), action: .download, local: nil, remote: $0)
        }
        for file in local.files {
            let location = CloudSavePath(root: file.root, path: file.path)
            decisions.append(.init(name: try XCTUnwrap(paths.remoteName(for: location)), location: location,
                action: file.path.contains("removed") ? .deleteLocal : .upload,
                local: .init(location: location, sha1: file.sha1, bytes: file.bytes, modifiedAt: file.modifiedAt), remote: nil))
        }
        let plan = CloudSyncPlan(gameID: gameID, installationID: installed.id, accountKey: remote.accountKey,
            remoteRevision: remote.revision, decisions: decisions, requiresAccountConfirmation: true)
        var operation = try store.beginCloudSync(installation: installed, accountKey: remote.accountKey, mapping: mapping)
        operation = try store.stageCloudSync(operation, plan: plan, remote: remote,
            localSnapshotID: local.id, remoteSnapshotID: downloaded.id)
        operation = try store.confirmCloudAccount(operation)
        operation = try store.markCloudApplying(operation)
        do {
            _ = try await saves.applyCloud(plan, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: [.game: game]) { _, _ in
                throw SourceFailure.network
            }
            XCTFail("Expected interruption")
        } catch SourceFailure.network {}
        return (root, game, store, installed, saves, server, operation)
    }

    func testRecoveryRestoresUploadsDownloadsAndDeletionsFromStagedCopiesOffline() async throws {
        let f = try await mixedPublication()
        try FileManager.default.moveItem(at: f.game, to: f.root.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: f.game, withIntermediateDirectories: true)
        await f.server.setOffline(true)
        let cloud = service(f.store, server: f.server, saves: f.saves, root: f.game)
        try await cloud.recoverInterruptedOperations()
        let result = await cloud.synchronize(f.installed, mapping: mapping)
        XCTAssertTrue(result.canPlayOffline, result.message)
        XCTAssertEqual(try read(f.game, name: "local.mountain"), "local awaiting upload")
        XCTAssertEqual(try read(f.game, name: "a.mountain"), "recovered a")
        XCTAssertEqual(try read(f.game, name: "z.mountain"), "recovered z")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.game.appendingPathComponent("saves/removed.mountain").path))
        let archived = try XCTUnwrap(f.store.cloudOperations().first { $0.id == f.operation.id })
        XCTAssertEqual(archived.phase, .superseded)
        XCTAssertEqual(archived.localRecoveries?.count, 1)
        XCTAssertNotNil(archived.localRecoveries?.last?.appliedPlan)
        XCTAssertEqual(archived.localSnapshotID, f.operation.localSnapshotID)
        XCTAssertEqual(archived.remoteSnapshotID, f.operation.remoteSnapshotID)
        let calls = await f.server.uploadCalls; XCTAssertEqual(calls, 0)
    }

    func testDifferentReplacementProgressRequiresCompleteCopyChoiceWhileOffline() async throws {
        for choice in [CloudSyncAuthorization.ConflictChoice.local, .remote] {
            let f = try await mixedPublication()
            try FileManager.default.moveItem(at: f.game, to: f.root.appendingPathComponent("original"))
            try put("new current progress", at: f.game, name: "a.mountain")
            try put("new extra slot", at: f.game, name: "extra.mountain")
            await f.server.setOffline(true)
            let cloud = service(f.store, server: f.server, saves: f.saves, root: f.game)
            try await cloud.recoverInterruptedOperations()
            let review = await cloud.synchronize(f.installed, mapping: mapping)
            XCTAssertEqual(review.state, .conflict, review.message); XCTAssertFalse(review.canPlayOffline)
            let operation = try XCTUnwrap(review.operation)
            XCTAssertTrue(operation.needsRecoveryReview)
            XCTAssertEqual(try read(f.game, name: "a.mountain"), "new current progress")
            XCTAssertThrowsError(try f.store.saveSession(.init(gameID: gameID, bottleID: f.installed.bottleID)))
            let chosen = await cloud.synchronize(f.installed, mapping: mapping,
                authorization: .init(operation: operation, conflictChoice: choice))
            XCTAssertTrue(chosen.canPlayOffline, chosen.message)
            XCTAssertEqual(try read(f.game, name: "a.mountain"), choice == .local ? "new current progress" : "recovered a")
            let names = try FileManager.default.contentsOfDirectory(atPath: f.game.appendingPathComponent("saves").path)
            XCTAssertEqual(Set(names), choice == .local ? ["a.mountain", "extra.mountain"] : ["a.mountain", "z.mountain", "local.mountain"])
            let localCopy = try XCTUnwrap(operation.localRecoveries?.last?.localSnapshotID)
            let preserved = try await f.saves.stagedContents(localCopy, gameID: gameID, location: .init(root: .game, path: "saves/extra.mountain"))
            XCTAssertEqual(preserved, Data("new extra slot".utf8))
            let calls = await f.server.uploadCalls; XCTAssertEqual(calls, 0)
        }
    }

    func testChangedRecoveryReviewCannotReuseConsentOrAttachAnotherAccount() async throws {
        let f = try await mixedPublication()
        try FileManager.default.moveItem(at: f.game, to: f.root.appendingPathComponent("original"))
        try put("current", at: f.game, name: "a.mountain")
        let cloud = service(f.store, server: f.server, saves: f.saves, root: f.game)
        try await cloud.recoverInterruptedOperations()
        let first = await cloud.synchronize(f.installed, mapping: mapping)
        try put("newer", at: f.game, name: "a.mountain")
        let stale = await cloud.synchronize(f.installed, mapping: mapping,
            authorization: .init(operation: try XCTUnwrap(first.operation), conflictChoice: .remote, attachAccount: true))
        XCTAssertEqual(stale.state, .conflict); XCTAssertTrue(stale.operation?.needsRecoveryReview == true)
        XCTAssertEqual(try read(f.game, name: "a.mountain"), "newer")
        await f.server.replace([], account: "account-b")
        let fresh = await cloud.synchronize(f.installed, mapping: mapping,
            authorization: .init(operation: try XCTUnwrap(stale.operation), conflictChoice: .remote, attachAccount: true))
        XCTAssertEqual(fresh.state, .conflict, fresh.message)
        XCTAssertFalse(fresh.operation?.needsLocalRecovery ?? true)
        XCTAssertTrue(fresh.operation?.plan?.requiresAccountConfirmation == true)
        XCTAssertEqual(try f.store.cloudAttachment(for: gameID, installationID: f.installed.id)?.accountKey, "account-a")
        XCTAssertEqual(try read(f.game, name: "a.mountain"), "recovered a")
        let calls = await f.server.uploadCalls; XCTAssertEqual(calls, 0)
    }

    func testRepeatedRecoveryUsesLastAcceptedCopyAfterAnotherReplacement() async throws {
        let f = try await mixedPublication()
        try FileManager.default.moveItem(at: f.game, to: f.root.appendingPathComponent("original"))
        try put("accepted current save", at: f.game, name: "a.mountain")
        var operation = try f.store.recoverInterruptedCloudSync(f.operation)
        operation = try f.store.resumeCloudSync(operation)
        let review = try await f.saves.stageLocalRecovery(XCTUnwrap(operation.plan),
            localSnapshotID: XCTUnwrap(operation.localSnapshotID), remoteSnapshotID: XCTUnwrap(operation.remoteSnapshotID), roots: [.game: f.game])
        operation = try f.store.stageCloudLocalRecovery(operation, recovery: review)
        operation = try f.store.authorizeCloudLocalRecovery(operation, choice: .local)
        // Crash after publishing the accepted receipt; then lose the replacement folder too.
        try FileManager.default.moveItem(at: f.game, to: f.root.appendingPathComponent("second-original"))
        try FileManager.default.createDirectory(at: f.game, withIntermediateDirectories: true)
        await f.server.setOffline(true)
        let cloud = service(f.store, server: f.server, saves: f.saves, root: f.game)
        try await cloud.recoverInterruptedOperations()
        let result = await cloud.synchronize(f.installed, mapping: mapping)
        XCTAssertTrue(result.canPlayOffline, result.message)
        XCTAssertEqual(try read(f.game, name: "a.mountain"), "accepted current save")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.game.appendingPathComponent("saves").path), ["a.mountain"])
        let history = try XCTUnwrap(f.store.cloudOperations().first { $0.id == f.operation.id })
        XCTAssertEqual(history.localRecoveries?.count, 2)
    }

    func testActiveSessionRejectsBackgroundSyncButAllowsItsOwnPrelaunchClaim() async throws {
        let root = try directory(), game = try directory(), store = try CatalogStore(), installed = installed(game)
        let saves = SaveStore(root: root); try store.saveInstallation(installed)
        let session = PlaySessionRecord(gameID: gameID, bottleID: installed.bottleID); try store.saveSession(session)
        let server = CloudServer(gameID: gameID, catalog: store), cloud = service(store, server: server, saves: saves, root: game)
        await server.replace([payload("remote")])
        let denied = await cloud.synchronize(installed, mapping: mapping)
        XCTAssertNotEqual(denied.state, .upToDate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent("saves/GameSaveNew.mountain").path))
        let allowed = await cloud.synchronize(installed, mapping: mapping, preparingSessionID: session.id)
        XCTAssertEqual(allowed.state, .upToDate, allowed.message)
        XCTAssertEqual(try read(game), "remote")
    }
}
