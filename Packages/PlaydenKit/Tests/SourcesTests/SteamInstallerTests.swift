import XCTest
import CryptoKit
import Domain
import SteamCore
import Runner
@testable import Sources

final class SteamInstallerTests: XCTestCase {
    private let game = SourceGameRecord(id: GameID(source: "steam", value: "100"), title: "Fixture")
    private func app(depots: [DepotInfo] = [DepotInfo(id: 101, manifestGID: 7)], launches: [AppLaunch] = [AppLaunch(id: "0", executable: "Game.exe")]) -> AppInfo {
        AppInfo(appID: 100, name: "Fixture", depots: depots, dlcAppIDs: [200, 300], launches: launches)
    }
    private func file(_ path: String, _ bytes: Data = Data("test".utf8)) -> DepotManifest.File {
        let sha = Data(Insecure.SHA1.hash(data: bytes))
        return .init(path: path, size: UInt64(bytes.count), chunks: [.init(sha: sha, offset: 0, compressedSize: UInt32(bytes.count), uncompressedSize: UInt32(bytes.count))], contentSHA1: sha)
    }
    private func manifest(_ files: [DepotManifest.File], depotID: UInt32 = 101, gid: UInt64 = 7) -> DepotManifest {
        .init(depotID: depotID, gid: gid, files: files, totalSize: files.reduce(0) { $0 + $1.size })
    }
    private func plan(_ files: [DepotManifest.File], app info: AppInfo? = nil) throws -> InstallPlan {
        try SteamPlanBuilder.build(game: game, app: info ?? app(), manifests: [manifest(files)], ownedApps: [100])
    }
    func testSpaceEstimateCountsOnlyPreparationBackupsAndVersionsLegacyPlans() throws {
        let resolved = try plan([file("Game.exe"), file("helper.EXE"), file("bin/steam_api64.dll"), file("asset.bin", Data(repeating: 1, count: 1000))])
        XCTAssertEqual(resolved.estimate.requiredBytes, 1012 + 12 + 256 * 1024 * 1024)
        XCTAssertEqual(try SteamPlanBuilder.payload(resolved, for: game.id).version, 2)
        let decoded = try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(resolved))
        XCTAssertEqual(try SteamPlanBuilder.payload(decoded, for: game.id).version, 2)
        var payload = try JSONDecoder().decode(SteamInstallPayload.self, from: resolved.sourcePayload)
        payload.version = 1
        func legacy(required: Int64) throws -> InstallPlan {
            .init(game: game, manifestIDs: resolved.manifestIDs,
                  estimate: .init(downloadBytes: 1012, installedBytes: 1012, requiredBytes: required),
                  launchSpec: resolved.launchSpec, sourcePayload: try JSONEncoder().encode(payload), recipeVersion: resolved.recipeVersion,
                  launchOptions: resolved.launchOptions)
        }
        let older = try legacy(required: 2024 + 1000 + 256 * 1024 * 1024)
        let roundtrip = try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(older))
        XCTAssertEqual(try SteamPlanBuilder.payload(roundtrip, for: game.id).version, 1)
        XCTAssertEqual(roundtrip.estimate, older.estimate)
        XCTAssertThrowsError(try SteamPlanBuilder.payload(legacy(required: resolved.estimate.requiredBytes), for: game.id))
        XCTAssertThrowsError(try SteamPlanBuilder.payload(legacy(required: older.estimate.requiredBytes + 1), for: game.id))
    }

    func testRemainingReservationMeasuresFilesAndRetainsRepairOverlap() async throws {
        let bytes = pe(), content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("asset.bin", bytes)])],
            entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), root = try temporaryDirectory()
        let initial = try await installer.remainingReservation(plan, at: root, staging: nil, repairing: false)
        XCTAssertEqual(initial, plan.estimate.requiredBytes)
        try await installer.download(plan, to: root) { _ in }
        let resumed = try await installer.remainingReservation(plan, at: root, staging: nil, repairing: false)
        XCTAssertEqual(resumed, plan.estimate.requiredBytes - Int64(bytes.count * 2))
        let repair = try await installer.remainingReservation(plan, at: root, staging: nil, repairing: true)
        XCTAssertEqual(repair, plan.estimate.requiredBytes, "Explicit repair must allow replacement even if receipt metadata matches")
    }

    func testSourceReservationResumeSharesUnchangedPartialVerificationWithWriter() async throws {
        let pieces = [Data("first".utf8), Data("second".utf8)]
        let chunks = pieces.enumerated().map { index, bytes in DepotManifest.Chunk(sha: Data(Insecure.SHA1.hash(data: bytes)),
            offset: index == 0 ? 0 : 5, compressedSize: UInt32(bytes.count), uncompressedSize: UInt32(bytes.count)) }
        let file = DepotManifest.File(path: "Game.exe", size: 11, chunks: chunks, contentSHA1: Data(Insecure.SHA1.hash(data: pieces[0] + pieces[1])))
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let root = try temporaryDirectory()
        var interrupted = ResumableDepotDownload(destination: root); interrupted.chunkConcurrency = 1
        do { try await interrupted.download(manifest: content.manifests[0]) { chunk in
            if chunk.offset > 0 { throw CancellationError() }; return pieces[0]
        } } catch is CancellationError {}
        let diagnostics = SteamPerformanceDiagnostics()
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content,
            chunks: Dictionary(uniqueKeysWithValues: zip(chunks.map(\.sha), pieces)), diagnostics: diagnostics), diagnostics: diagnostics)
        let plan = try await installer.resolve()
        for _ in 0..<3 {
            let remaining = try await installer.remainingReservation(plan, at: root, staging: nil, repairing: false)
            XCTAssertEqual(remaining, plan.estimate.requiredBytes - 5)
        }
        try await installer.download(plan, to: root) { _ in }
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 5)
    }
    func testRepairGateUsesEntireInvalidSubsetWithoutAssumingOldExtentReclamation() async throws {
        let bytes = Data("original".utf8), files = [file("Game.exe", bytes)] + (0..<20).map { file("asset-\($0)", bytes) }
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(files)], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let diagnostics = SteamPerformanceDiagnostics(), root = try temporaryDirectory()
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content,
            chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes], diagnostics: diagnostics), diagnostics: diagnostics)
        let plan = try await installer.resolve()
        try await installer.download(plan, to: root) { _ in }
        for file in files.dropFirst() { try Data(repeating: 9, count: bytes.count).write(to: root.appendingPathComponent(file.path)) }
        let provisional = try await installer.remainingReservation(plan, at: root, staging: nil, repairing: true)
        XCTAssertEqual(provisional, plan.estimate.requiredBytes - plan.estimate.installedBytes + 8 * Int64(bytes.count))
        do {
            try await installer.repair(plan, at: root, staging: nil, reserve: { required, allocated in
                XCTAssertEqual(required, plan.estimate.requiredBytes - Int64(bytes.count))
                XCTAssertEqual(allocated, 0)
                throw OperationFailure(stage: "Reserve space", reason: "fixture", output: "")
            }, progress: { _ in })
            XCTFail("Low space must stop replacement before any transfer")
        } catch let failure as OperationFailure { XCTAssertEqual(failure.stage, "Reserve space") }
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, UInt64(files.count * bytes.count), "The repair performs one full inspection")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("asset-0")), Data(repeating: 9, count: bytes.count))
    }
    func testNewRepairOfLegacyPlanUsesCurrentBackupBudgetWithoutRewritingPlan() async throws {
        let bytes = Data("original".utf8), content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("asset.bin", bytes)])],
            entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let legacy = try SteamPlanBuilder.build(game: game, app: content.app, manifests: content.manifests, ownedApps: [100], payloadVersion: 1)
        let estimate = legacy.estimate, root = try temporaryDirectory()
        try await installer.download(legacy, to: root) { _ in }
        try Data("corrupt!".utf8).write(to: root.appendingPathComponent("asset.bin"))
        do {
            try await installer.repair(legacy, at: root, staging: nil, reserve: { required, allocated in
                XCTAssertEqual(required, 256 * 1024 * 1024 + Int64(bytes.count * 2))
                XCTAssertEqual(allocated, 0)
                throw CancellationError()
            }, progress: { _ in })
        } catch is CancellationError {}
        let afterDownload = try await installer.remainingReservation(legacy, at: root, staging: nil, repairing: true, downloadComplete: true)
        XCTAssertEqual(afterDownload, 256 * 1024 * 1024 + Int64(bytes.count))
        XCTAssertEqual(legacy.estimate, estimate)
        XCTAssertEqual(try SteamPlanBuilder.payload(legacy, for: game.id).version, 1)
    }
    func testSpaceArithmeticRejectsOverflow() {
        XCTAssertThrowsError(try SteamPlanBuilder.requiredBytes(installed: .max, backups: 1, largest: 0, version: 2))
        XCTAssertThrowsError(try SteamPlanBuilder.requiredBytes(installed: UInt64(Int64.max), backups: 0, largest: 0, version: 2))
        XCTAssertThrowsError(try SteamPlanBuilder.requiredBytes(installed: UInt64(Int64.max), backups: 0, largest: 0, version: 1))
    }

    func testRestartedStagesReuseReceiptsIncludingLegitimateOrigFiles() async throws {
        let bytes = pe(), asset = Data(repeating: 7, count: 128 * 1024)
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("asset.orig", asset)])],
            entitlements: .init(appIDs: [100], depotIDs: [101]))
        let backend = FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes, Data(Insecure.SHA1.hash(data: asset)): asset])
        let directory = try temporaryDirectory(), initial = SteamInstaller(game: game, backend: backend)
        let plan = try await initial.resolve()
        try await initial.download(plan, to: directory) { _ in }
        let diagnostics = SteamPerformanceDiagnostics()
        for _ in 0..<2 {
            let restarted = SteamInstaller(game: game, backend: backend, diagnostics: diagnostics)
            let check = try await restarted.verifyOriginals(plan, at: directory, staging: nil)
            XCTAssertTrue(check.isValid)
            let staging = try await restarted.postInstall(plan, at: directory)
            _ = try await restarted.validate(plan, at: directory, staging: staging)
        }
        XCTAssertEqual(diagnostics.snapshot()[.sha1].bytes, 0, "All stage content checks should reuse completion receipts")
        try Data("damage".utf8).write(to: directory.appendingPathComponent("asset.orig"))
        let check = try await initial.verifyOriginals(plan, at: directory, staging: nil)
        XCTAssertEqual(check.invalidFiles, ["asset.orig"], "Restart proof must still reject changed content")
    }

    func testRepairInspectsOlderInstallOnceAndDownloadsOnlyInvalidFiles() async throws {
        let bytes = pe(), asset = Data(repeating: 7, count: 128 * 1024)
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("asset.bin", asset)])],
            entitlements: .init(appIDs: [100], depotIDs: [101]))
        let diagnostics = SteamPerformanceDiagnostics()
        let backend = FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes, Data(Insecure.SHA1.hash(data: asset)): asset], diagnostics: diagnostics)
        let installer = SteamInstaller(game: game, backend: backend, diagnostics: diagnostics)
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try bytes.write(to: directory.appendingPathComponent("Game.exe"))
        try Data(repeating: 8, count: asset.count).write(to: directory.appendingPathComponent("asset.bin"))
        try await installer.repair(plan, at: directory, staging: nil) { _ in }
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, UInt64(bytes.count + asset.count), "Repair must inspect content exactly once")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("asset.bin")), asset)
        let before = diagnostics.snapshot()[.contentRead].bytes
        let restarted = SteamInstaller(game: game, backend: backend, diagnostics: diagnostics)
        let checked = try await restarted.verifyOriginals(plan, at: directory, staging: nil)
        XCTAssertTrue(checked.isValid)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, before, "Full repair refreshes valid older files too")
    }

    func testInterruptedBackupCopyRecoversFromIntactOriginalBeforeStagingReceipt() async throws {
        for path in ["steam_api64.dll", "Game.exe"] {
            let original = pe(section: path == "Game.exe" ? ".bind" : ".text")
            let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", original), file("steam_api64.dll", original)])],
                entitlements: .init(appIDs: [100], depotIDs: [101]))
            let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content,
                chunks: [Data(Insecure.SHA1.hash(data: original)): original]), runtimeTools: FixtureUnpackingTools(output: pe()))
            let plan = try await installer.resolve(), directory = try temporaryDirectory()
            try await installer.download(plan, to: directory) { _ in }
            try original.prefix(128).write(to: directory.appendingPathComponent(path + ".orig"))
            let bottle = GameBottle(gameID: game.id, name: "playden-steam-100", ownershipToken: UUID())
            let staging = try await installer.postInstall(plan, at: directory, in: bottle)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(path + ".orig")), original)
            _ = try await installer.validate(plan, at: directory, staging: staging)
        }
    }

    func testPreparedStagesHashOnlyMappedBackupsAndRemoveTheirReceiptTrust() async throws {
        let bytes = pe(), asset = Data(repeating: 3, count: 128 * 1024)
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("bin\\steam_api64.dll", bytes), file("assets.orig", asset)])],
            entitlements: .init(appIDs: [100], depotIDs: [101]))
        let backend = FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes, Data(Insecure.SHA1.hash(data: asset)): asset])
        let diagnostics = SteamPerformanceDiagnostics(), installer = SteamInstaller(game: game, backend: backend, diagnostics: diagnostics)
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let staging = try await installer.postInstall(plan, at: directory)
        XCTAssertEqual(diagnostics.snapshot()[.sha1].bytes, 0)
        for _ in 0..<2 {
            let restarted = SteamInstaller(game: game, backend: backend, diagnostics: diagnostics)
            _ = try await restarted.validate(plan, at: directory, staging: staging)
        }
        XCTAssertEqual(diagnostics.snapshot()[.sha1].bytes, 2048, "Only the 1 KiB original API is hashed on each validation")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(".gn-download/receipts/101-7.json"))) as? [String: Any])
        let entries = try XCTUnwrap(json["entries"] as? [String: Any])
        XCTAssertEqual(Set(entries.keys), ["Game.exe", "assets.orig"], "Prepared and backup paths cannot retain receipt trust")
        try Data(repeating: 0, count: bytes.count).write(to: directory.appendingPathComponent("bin/steam_api64.dll.orig"))
        do { _ = try await installer.postInstall(plan, at: directory); XCTFail("Damaged backup and prepared live DLL must not be accepted as originals") } catch {}
        try await installer.repair(plan, at: directory, staging: staging) { _ in }
        let repaired = try await installer.postInstall(plan, at: directory)
        _ = try await installer.validate(plan, at: directory, staging: repaired)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("bin/steam_api64.dll.orig")), bytes)
    }

    func testExplicitRepairIgnoresMatchingReceipts() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("asset.bin", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let diagnostics = SteamPerformanceDiagnostics()
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content,
            chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]), diagnostics: diagnostics)
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        try await installer.repair(plan, at: directory, staging: nil) { _ in }
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 2048)
        let checked = try await installer.verifyOriginals(plan, at: directory, staging: nil)
        XCTAssertTrue(checked.isValid)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 2048)
    }

    func testInterruptedTargetedRepairKeepsDepotStateUntilAllTargetsComplete() async throws {
        let bytes = pe(), asset = Data("asset".utf8)
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("asset.bin", asset)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let partialBackend = FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes])
        let installer = SteamInstaller(game: game, backend: partialBackend)
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        let stale = directory.appendingPathComponent(".gn-download/101/6/other.partial")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("checkpoint".utf8).write(to: stale)
        do { try await installer.repair(plan, at: directory, staging: nil) { _ in }; XCTFail("Missing fixture chunk should interrupt repair") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path), "A completed target cannot clean the authoritative depot yet")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Game.exe")), bytes)
        let complete = SteamInstaller(game: game, backend: FixtureContentBackend(content: content,
            chunks: [Data(Insecure.SHA1.hash(data: asset)): asset]))
        try await complete.repair(plan, at: directory, staging: nil) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("asset.bin")), asset)
        let checked = try await complete.verifyOriginals(plan, at: directory, staging: nil)
        XCTAssertTrue(checked.isValid)
    }

    func testInterruptedBackupRecoveryPreservesUnexpectedBackupDirectory() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("steam_api64.dll", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let backup = directory.appendingPathComponent("steam_api64.dll.orig")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let sentinel = backup.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        do { _ = try await installer.postInstall(plan, at: directory); XCTFail("An unexpected directory must not be removed as an interrupted file copy") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testUnpackingRejectsReplacedTemporaryWorkspaceAfterAwait() async throws {
        let original = pe(section: ".bind"), unpacked = pe()
        let tools = ReplacingUnpackWorkspace(output: unpacked)
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", original)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: original)): original]), runtimeTools: tools)
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        let bottle = GameBottle(gameID: game.id, name: "fixture", ownershipToken: UUID())
        try await installer.download(plan, to: directory) { _ in }
        do { _ = try await installer.postInstall(plan, at: directory, in: bottle); XCTFail("Replaced temporary workspace accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Game.exe")), original)
        await tools.cleanup()
    }

    func testPreparationRejectsLinkedWriteLeavesAcrossRestart() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("steam_api64.dll", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let backend = FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes])
        let installer = SteamInstaller(game: game, backend: backend), plan = try await installer.resolve()
        let leaves = ["steam_api64.dll", "steam_api64.dll.orig", ".steam_dll_restored", "orig_dll_path.txt", ".steam_dll_replaced",
                      "steam_interfaces.txt", "steam_appid.txt", "steam_settings/steam_interfaces.txt", "steam_settings/steam_appid.txt",
                      "steam_settings/depots.txt", "steam_settings/configs.user.ini", "steam_settings/configs.app.ini",
                      "steam_settings/configs.main.ini", "steam_settings/supported_languages.txt"]
        for leaf in leaves {
            let directory = try temporaryDirectory(), outside = try temporaryDirectory().appendingPathComponent("keep")
            try bytes.write(to: outside)
            try await installer.download(plan, to: directory) { _ in }
            _ = try await installer.postInstall(plan, at: directory)
            let target = directory.appendingPathComponent(leaf)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            let restarted = SteamInstaller(game: game, backend: backend)
            do { _ = try await restarted.postInstall(plan, at: directory); XCTFail("Linked write accepted: " + leaf) } catch {}
            XCTAssertEqual(try Data(contentsOf: outside), bytes, leaf)
        }
        let directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let foreign = GameBottle(gameID: .init(source: "steam", value: "other"), name: "foreign", ownershipToken: UUID())
        do { _ = try await installer.postInstall(plan, at: directory, in: foreign); XCTFail("Foreign bottle accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("steam_api64.dll.orig").path))
    }

    func testPreparationUsesOnlyManifestFilesAndIgnoresUnrelatedLinks() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("steam_api64.dll", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let unrelated = directory.appendingPathComponent("user-assets")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("not a DLL".utf8).write(to: unrelated.appendingPathComponent("steam_api64.dll"))
        try FileManager.default.createSymbolicLink(atPath: unrelated.appendingPathComponent("link").path, withDestinationPath: "missing")
        let staging = try await installer.postInstall(plan, at: directory)
        XCTAssertEqual(staging.mutations.map(\.relativePath), ["steam_api64.dll"])
        _ = try await installer.validate(plan, at: directory, staging: staging)
        XCTAssertEqual(try Data(contentsOf: unrelated.appendingPathComponent("steam_api64.dll")), Data("not a DLL".utf8))
    }

    func testRuntimeOptionsRejectLinkedAncestorAboveAPIParent() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("engine/bin/steam_api64.dll", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory(), outside = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        _ = try await installer.postInstall(plan, at: directory)
        let engine = directory.appendingPathComponent("engine"), moved = outside.appendingPathComponent("engine")
        try FileManager.default.moveItem(at: engine, to: moved)
        try FileManager.default.createSymbolicLink(at: engine, withDestinationURL: moved)
        do { try await installer.applyRuntimeOptions(["steam.overlay": "1"], plan: plan, at: directory); XCTFail("Linked ancestor accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("bin/steam_settings/configs.overlay.ini").path))
    }

    func testUnpackingRejectsReplacedInstallationAfterAwait() async throws {
        let original = pe(section: ".bind"), unpacked = pe(), directory = try temporaryDirectory()
        let moved = directory.appendingPathExtension("moved")
        addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
        let tools = FixtureUnpackingTools(output: unpacked, duringRun: {
            try FileManager.default.moveItem(at: directory, to: moved)
            try FileManager.default.copyItem(at: moved, to: directory)
        })
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", original)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: original)): original]), runtimeTools: tools)
        let plan = try await installer.resolve(), bottle = GameBottle(gameID: game.id, name: "fixture", ownershipToken: UUID())
        try await installer.download(plan, to: directory) { _ in }
        do { _ = try await installer.postInstall(plan, at: directory, in: bottle); XCTFail("A different directory accepted after unpacking") } catch {}
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Game.exe")), original)
    }

    func testDiagnosticsIncludePreparationScansHashesAndFinalValidation() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("steam_api64.dll", bytes)])],
            entitlements: .init(appIDs: [100], depotIDs: [101]))
        let diagnostics = SteamPerformanceDiagnostics()
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content,
            chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]), diagnostics: diagnostics)
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let staging = try await installer.postInstall(plan, at: directory)
        let prepared = diagnostics.snapshot()
        XCTAssertEqual(prepared[.preparation].count, 1)
        XCTAssertEqual(prepared[.emulatorPreparation].count, 1)
        XCTAssertGreaterThanOrEqual(prepared[.directoryWalk].count, 3)
        XCTAssertGreaterThan(prepared[.sha256].bytes, 1024 * 1024, "Include bundled asset hashing within SteamPreparer")
        XCTAssertGreaterThan(prepared[.contentRead].bytes, prepared[.sha256].bytes, "Include PE inspection and interface extraction reads")
        _ = try await installer.validate(plan, at: directory, staging: staging)
        let validated = diagnostics.snapshot()
        XCTAssertEqual(validated[.finalValidation].count, 1)
        XCTAssertGreaterThan(validated[.sha1].bytes, prepared[.sha1].bytes)
        XCTAssertGreaterThan(validated[.sha256].bytes, prepared[.sha256].bytes)
        XCTAssertGreaterThan(validated[.directoryWalk].count, prepared[.directoryWalk].count)
    }

    func testSteamStubDiagnosticsIncludeBundledToolHashes() async throws {
        let original = pe(section: ".bind"), unpacked = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", original)])],
            entitlements: .init(appIDs: [100], depotIDs: [101]))
        let diagnostics = SteamPerformanceDiagnostics()
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content,
            chunks: [Data(Insecure.SHA1.hash(data: original)): original]),
            runtimeTools: FixtureUnpackingTools(output: unpacked), diagnostics: diagnostics)
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let bottle = GameBottle(gameID: game.id, name: "playden-steam-100", ownershipToken: UUID())
        _ = try await installer.postInstall(plan, at: directory, in: bottle)
        XCTAssertGreaterThan(diagnostics.snapshot()[.sha256].bytes, UInt64(original.count * 2 + unpacked.count),
            "Include SHA-256 tool integrity checks inside executable preparation")
    }

    func testCloudCapabilityDoesNotValidateDepotOrLaunchContent() throws {
        let info = AppInfo(appID: 100, name: "Fixture", ufs: UFS(quota: 1024))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(
            content: .init(app: info, manifests: [], entitlements: .init(appIDs: [100], depotIDs: [])), chunks: [:]))
        func saved(_ info: AppInfo, version: Int = 1) throws -> InstallPlan {
            // Intentionally invalid install content: the display hint must not rebuild it.
            var payload = SteamInstallPayload(app: info, manifests: [], ownedDLC: [])
            payload.version = version
            return InstallPlan(game: game, manifestIDs: [:],
                estimate: .init(downloadBytes: 0, installedBytes: 0, requiredBytes: 0),
                launchSpec: .init(executableRelativePath: "missing.exe"), sourcePayload: try JSONEncoder().encode(payload))
        }
        let plan = try saved(info)
        let sourceInstaller: any Installer = installer
        XCTAssertTrue(try sourceInstaller.supportsCloudSaves(plan))
        XCTAssertThrowsError(try installer.saveMapping(plan), "Actual save operations must still validate the full plan")
        XCTAssertFalse(try installer.supportsCloudSaves(saved(AppInfo(appID: 100, name: "No Cloud"))))
        XCTAssertFalse(try installer.supportsCloudSaves(saved(AppInfo(appID: 100, name: "Unresolved", ufs:
            UFS(saveFilePatterns: [.init(root: .WinMyDocuments, path: "../outside", pattern: "*")])))))
        XCTAssertTrue(try installer.supportsCloudSaves(saved(info, version: 2)))
        XCTAssertThrowsError(try installer.supportsCloudSaves(saved(info, version: 3)))
        XCTAssertThrowsError(try installer.supportsCloudSaves(saved(AppInfo(appID: 999, name: "Wrong game", ufs: UFS(quota: 1)))))
    }

    func testWindowsEnglishDepotsIncludeOnlyOwnedDLC() throws {
        let info = app(depots: [
            .init(id: 101, osList: "windows,linux", manifestGID: 7),
            .init(id: 102, osList: "macos", manifestGID: 8),
            .init(id: 103, language: "french", manifestGID: 9),
            .init(id: 104, isSharedInstall: true, manifestGID: 10),
            .init(id: 105, isDLC: true, dlcAppID: 200, manifestGID: 11),
            .init(id: 106, isDLC: true, dlcAppID: 300, manifestGID: 12)
        ])
        XCTAssertEqual(try SteamPlanBuilder.selectedDepots(info, ownedApps: [100, 200]).map(\.id), [101, 105])
        let result = try SteamPlanBuilder.build(game: game, app: info,
            manifests: [manifest([file("Game.exe")]), manifest([file("DLC/data.bin")], depotID: 105, gid: 11)], ownedApps: [100, 200])
        XCTAssertEqual(try SteamPlanBuilder.payload(result, for: game.id).ownedDLC, [200])
        XCTAssertEqual(result.estimate.installedBytes, 8)
        XCTAssertEqual(result.estimate.downloadBytes, 8)
        XCTAssertGreaterThan(result.estimate.requiredBytes, 16)
        XCTAssertThrowsError(try SteamPlanBuilder.build(game: game, app: info, manifests: [], ownedApps: [200]))
    }
    func testRegionalDepotRequiresPackageEntitlementEvenWhenBaseAppIsOwned() async throws {
        // The same base app can list mutually exclusive regional depots with no dlcappid.
        let info = app(depots: [.init(id: 101, osList: "windows", manifestGID: 7),
                                .init(id: 102, osList: "windows", manifestGID: 8),
                                .init(id: 103, osList: "windows")])
        let content = ResolvedSteamContent(app: info, manifests: [manifest([file("Game.exe")])],
                                          entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [:]))
        let resolved = try await installer.resolve()
        XCTAssertEqual(resolved.manifestIDs, ["101": "7"])
        let payload = try SteamPlanBuilder.payload(resolved, for: game.id)
        XCTAssertEqual(payload.authorizedDepotIDs, [101])
        XCTAssertEqual(payload.app.depots.count, 3, "Keep original metadata while pinning the entitled subset")
        XCTAssertEqual(try SteamPlanBuilder.selectedDepots(info, ownedApps: [100], ownedDepots: [101]).map(\.id), [101])
        XCTAssertThrowsError(try SteamPlanBuilder.selectedDepots(info, ownedApps: [100], ownedDepots: []))
        XCTAssertThrowsError(try SteamPlanBuilder.build(game: game, app: info,
            manifests: [manifest([file("Game.exe")]), manifest([file("other.exe")], depotID: 102, gid: 8)],
            ownedApps: [100], ownedDepots: [101]))
    }
    func testLegacyPlansRemainReadableAndEntitlementPinsCannotBeRemovedFromSubsetPlans() throws {
        let legacy = try plan([file("Game.exe")])
        XCTAssertNil(try SteamPlanBuilder.payload(legacy, for: game.id).authorizedDepotIDs)
        let info = app(depots: [.init(id: 101, manifestGID: 7), .init(id: 102, manifestGID: 8)])
        let resolved = try SteamPlanBuilder.build(game: game, app: info,
            manifests: [manifest([file("Game.exe")])], ownedApps: [100], ownedDepots: [101])
        var payload = try SteamPlanBuilder.payload(resolved, for: game.id)
        payload.authorizedDepotIDs = nil
        let altered = InstallPlan(game: game, manifestIDs: resolved.manifestIDs, estimate: resolved.estimate,
            launchSpec: resolved.launchSpec, sourcePayload: try JSONEncoder().encode(payload))
        XCTAssertThrowsError(try SteamPlanBuilder.payload(altered, for: game.id))
    }
    func testInstallDiagnosticReportsCodesWithoutSecretsOrSignedURLs() {
        XCTAssertEqual(SteamInstallDiagnostics.code(for: SteamError.http(status: 403, url: "https://fixture.invalid/secret")), "HTTP 403")
        XCTAssertEqual(SteamInstallDiagnostics.code(for: SteamError.eresult(.accessDenied, context: "private context")), "Steam EResult 15")
        XCTAssertEqual(SteamInstallDiagnostics.code(for: SteamError.download("private request")), "Content verification failed")
    }
    func testPlanRejectsMissingManifestConflictsTraversalAndIncompleteChunks() throws {
        XCTAssertThrowsError(try plan([file("Game.exe")], app: app(depots: [.init(id: 101)])))
        XCTAssertThrowsError(try plan([file("Game.exe"), file("../outside")]))
        XCTAssertThrowsError(try plan([file("Game.exe"), file("GAME.exe")]))
        XCTAssertThrowsError(try plan([.init(path: "Game.exe", size: 20, chunks: [])]))
        let info = app(depots: [.init(id: 101, manifestGID: 7), .init(id: 102, manifestGID: 8)])
        XCTAssertThrowsError(try SteamPlanBuilder.build(game: game, app: info,
            manifests: [manifest([file("Game.exe")]), manifest([file("Game.exe/child")], depotID: 102, gid: 8)], ownedApps: [100]))
    }
    func testIdenticalSharedFilesAreCountedAndDownloadedOnce() throws {
        let shared = file("shared.bin")
        let result = try SteamPlanBuilder.build(game: game, app: app(depots: [.init(id: 101, manifestGID: 7), .init(id: 102, manifestGID: 8)]),
            manifests: [manifest([file("Game.exe"), shared]), manifest([shared], depotID: 102, gid: 8)], ownedApps: [100])
        let payload = try SteamPlanBuilder.payload(result, for: game.id)
        XCTAssertEqual(result.estimate.installedBytes, 8)
        XCTAssertTrue(payload.manifests[1].files.isEmpty)
    }
    func testLaunchSelectionUsesExplicitDefaultAndManifestCasingWithoutGuessing() throws {
        let options = [AppLaunch(id: "0", executable: "bin/game.exe", arguments: #"--name "two words""#, workingDirectory: "bin", type: "default"),
                       AppLaunch(id: "1", executable: "Config.exe"), AppLaunch(id: "2", executable: "Mac.app", osList: "macos")]
        let result = try plan([file("Bin/Game.exe"), file("Config.exe")], app: app(launches: options))
        XCTAssertEqual(result.launchSpec.executableRelativePath, "Bin/Game.exe")
        XCTAssertEqual(result.launchSpec.workingDirectoryRelativePath, "Bin")
        XCTAssertEqual(result.launchSpec.arguments, ["--name", "two words"])
        XCTAssertEqual(result.launchOptions?.map(\.id), ["0", "1"])
        let legacy = InstallPlan(game: game, manifestIDs: result.manifestIDs, estimate: result.estimate,
            launchSpec: result.launchSpec, sourcePayload: result.sourcePayload)
        let offline = SteamInstaller(game: game, backend: FixtureContentBackend(content: .init(app: app(), manifests: [], entitlements: .init(appIDs: [], depotIDs: [])), chunks: [:]))
        XCTAssertEqual(try offline.launchOptions(legacy), result.launchOptions, "Recover older installations' choices without resolving online")
        let modes = try plan([file("Game.exe")], app: app(launches: [
            .init(id: "0", executable: "Game.exe", arguments: "-dx11", description: "Play with DirectX 11"),
            .init(id: "1", executable: "Game.exe", arguments: "-dx12", description: "Play with DirectX 12")]))
        XCTAssertEqual(modes.launchOptions?.map(\.title), ["Play with DirectX 11", "Play with DirectX 12"])
        XCTAssertEqual(modes.launchOptions?.last?.spec.arguments, ["-dx12"])
        XCTAssertNoThrow(try SteamPlanBuilder.payload(modes, for: game.id))
        let altered = InstallPlan(game: game, manifestIDs: modes.manifestIDs, estimate: modes.estimate,
            launchSpec: modes.launchSpec, sourcePayload: modes.sourcePayload,
            launchOptions: [.init(id: "1", title: "Other", spec: .init(executableRelativePath: "Other.exe"))])
        XCTAssertThrowsError(try SteamPlanBuilder.payload(altered, for: game.id))
        XCTAssertThrowsError(try plan([file("Game.exe")], app: app(launches: [.init(id: "0", executable: "../Game.exe")])))
    }
    func testPublicInstallExcludesDeveloperBranchLaunchAndUnownedArtbook() throws {
        // Armored Core VI advertises a dev-debug executable beside its public launcher.
        let options = [AppLaunch(id: "0", executable: "Game/start_protected_game.exe"),
                       AppLaunch(id: "1", executable: "Artbook/Artbook.exe", requiredDLC: 200),
                       AppLaunch(id: "2", executable: "Game/Debug.exe", betaKey: "dev-debug")]
        let result = try plan([file("Game/start_protected_game.exe")], app: app(launches: options))
        XCTAssertEqual(result.launchSpec.executableRelativePath, "Game/start_protected_game.exe")
        XCTAssertEqual(try SteamPlanBuilder.payload(result, for: game.id).app.launches, options)
        XCTAssertThrowsError(try plan([file("Game/Debug.exe")], app: app(launches: [options[2]])))
        for branch in ["", "public"] {
            XCTAssertNoThrow(try plan([file("Game.exe")], app: app(launches: [.init(id: "0", executable: "Game.exe", betaKey: branch)])))
        }
        let gated = AppInfo(appID: 100, name: "Fixture", depots: [.init(id: 101, manifestGID: 7)],
            launches: [.init(id: "0", executable: "Game.exe", requiredDLC: 900)])
        let ownedMode = try SteamPlanBuilder.build(game: game, app: gated, manifests: [manifest([file("Game.exe")])], ownedApps: [100, 900])
        XCTAssertEqual(try SteamPlanBuilder.payload(ownedMode, for: game.id).ownedDLC, [900], "Keep launch-only DLC gates when revalidating an offline plan")
    }
    func testStoreLauncherHandoffExplainsUnsupportedLauncherInsteadOfPathError() throws {
        // Need for Speed Most Wanted (1262560) and Mirror's Edge Catalyst (1233570) launch only through the EA app.
        let ea = app(launches: [.init(id: "0", executable: "steam2ea://launchgame/1262560?platform=steam&theme=nfsmw")])
        XCTAssertThrowsError(try plan([file("Game.exe")], app: ea)) {
            XCTAssertEqual(($0 as? OperationFailure)?.reason, "This game launches through the EA app, which Playden doesn’t support yet.")
        }
        let other = app(launches: [.init(id: "0", executable: "uplay://launch/123/0")])
        XCTAssertThrowsError(try plan([file("Game.exe")], app: other)) {
            XCTAssertEqual(($0 as? OperationFailure)?.reason, "This game launches through another store’s launcher, which Playden doesn’t support yet.")
        }
    }
    func testWindowsArgumentsKeepQuotesBackslashesEmptyValuesAndShellSyntaxLiteral() throws {
        XCTAssertEqual(try WindowsArguments.parse(#"one "two three" "" four" five""#), ["one", "two three", "", "four five"])
        XCTAssertEqual(try WindowsArguments.parse(#""C:\My Games\\" a\"b "say ""yes""""#), ["C:\\My Games\\", "a\"b", "say \"yes\""])
        XCTAssertEqual(try WindowsArguments.parse(#"$HOME $(whoami) `id` ; *"#), ["$HOME", "$(whoami)", "`id`", ";", "*"])
        XCTAssertThrowsError(try WindowsArguments.parse("a\0b"))
    }
    func testCorruptSavedPlansFailWithoutDuplicateKeyOrIntegerTraps() throws {
        let original = try plan([file("Game.exe")])
        var payload = try JSONDecoder().decode(SteamInstallPayload.self, from: original.sourcePayload)
        payload = SteamInstallPayload(app: payload.app, manifests: payload.manifests + payload.manifests, ownedDLC: [])
        let duplicate = InstallPlan(game: game, manifestIDs: original.manifestIDs, estimate: original.estimate,
            launchSpec: original.launchSpec, sourcePayload: try JSONEncoder().encode(payload))
        XCTAssertThrowsError(try SteamPlanBuilder.payload(duplicate, for: game.id))
        let altered = InstallPlan(game: game, manifestIDs: original.manifestIDs, estimate: original.estimate,
            launchSpec: LaunchSpec(executableRelativePath: "../other.exe"), sourcePayload: original.sourcePayload)
        XCTAssertThrowsError(try SteamPlanBuilder.payload(altered, for: game.id))
        let wrongTotal = SteamInstallPayload(app: app(), manifests: [.init(depotID: 101, gid: 7, files: [file("Game.exe")], totalSize: UInt64.max)], ownedDLC: [])
        let oversized = InstallPlan(game: game, manifestIDs: original.manifestIDs, estimate: original.estimate,
            launchSpec: original.launchSpec, sourcePayload: try JSONEncoder().encode(wrongTotal))
        XCTAssertThrowsError(try SteamPlanBuilder.payload(oversized, for: game.id))
    }
    func testVerificationProgressSpansDepotsAndPreparedFiles() async throws {
        let bytes = pe()
        let info = app(depots: [.init(id: 101, manifestGID: 7), .init(id: 102, manifestGID: 8)])
        let content = ResolvedSteamContent(app: info, manifests: [manifest([file("Game.exe", bytes)]),
            manifest([file("steam_api64.dll", bytes)], depotID: 102, gid: 8)], entitlements: .init(appIDs: [100], depotIDs: [101, 102]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let original = VerificationSamples()
        let result = try await installer.verifyOriginals(plan, at: directory, staging: nil, progress: original.append)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(original.values.first?.bytesChecked, 0)
        XCTAssertEqual(original.values.last?.bytesChecked, 2048)
        XCTAssertTrue(original.values.contains { $0.bytesChecked == 1024 })
        XCTAssertTrue(original.values.allSatisfy { $0.bytesTotal == 2048 && $0.scope == .installation })
        let preparation = PreparationSamples()
        let bottle = GameBottle(gameID: game.id, name: "fixture", ownershipToken: UUID())
        let staging = try await installer.postInstall(plan, at: directory, in: bottle, progress: preparation.append)
        let checks = preparation.values.compactMap { if case .verifying(let value) = $0.step { value } else { nil as InstallFileVerification? } }
        XCTAssertEqual(checks.first?.bytesChecked, 0); XCTAssertEqual(checks.last?.bytesChecked, 2048)
        XCTAssertTrue(checks.contains { $0.file == "Game.exe" })
        XCTAssertTrue(preparation.values.contains { $0.step == .preparingExecutable("Game.exe") })
        XCTAssertEqual(preparation.values.last?.step, .applyingSettings)
        XCTAssertEqual(preparation.values.map(\.sequence), Array(1...UInt64(preparation.values.count)))
        let final = VerificationSamples()
        _ = try await installer.validate(plan, at: directory, staging: staging, progress: final.append)
        let expected = Int64(2048 + (try Data(contentsOf: directory.appendingPathComponent("steam_api64.dll"))).count)
        XCTAssertEqual(final.values.last?.bytesChecked, expected)
        XCTAssertTrue(final.values.allSatisfy { $0.bytesTotal == expected })
        XCTAssertEqual(final.values.map(\.bytesChecked), final.values.map(\.bytesChecked).sorted())
    }
    func testDownloadStageRetryVerifyAndChangedReplacementDetection() async throws {
        let bytes = pe(), dll = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("bin\\steam_api64.dll", dll)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let first = try await installer.postInstall(plan, at: directory)
        XCTAssertEqual(first.mutations.map(\.relativePath), ["bin/steam_api64.dll"])
        let prepared = try await installer.validate(plan, at: directory, staging: first)
        XCTAssertEqual(prepared.dllOverrides, ["steam_api64=n,b"])
        let second = try await installer.postInstall(plan, at: directory)
        XCTAssertEqual(first, second, "Retry must retain original DLLs and the same staged content")
        let settings = try String(contentsOf: directory.appendingPathComponent("bin/steam_settings/configs.app.ini"), encoding: .utf8)
        XCTAssertTrue(settings.contains("unlock_all=0"))
        let connectivity = try String(contentsOf: directory.appendingPathComponent("bin/steam_settings/configs.main.ini"), encoding: .utf8)
        XCTAssertTrue(connectivity.contains("offline=1\n"))
        XCTAssertTrue(connectivity.contains("disable_networking=1\n"), "Offline installs must not enable LAN discovery and trigger macOS local-network prompts")
        try Data("broken".utf8).write(to: directory.appendingPathComponent("bin/steam_api64.dll"))
        let originals = try await installer.verifyOriginals(plan, at: directory, staging: first)
        XCTAssertTrue(originals.isValid)
        do { _ = try await installer.validate(plan, at: directory, staging: first); XCTFail("Changed replacement accepted") } catch {}
        try Data("broken".utf8).write(to: directory.appendingPathComponent("bin/steam_api64.dll.orig"))
        let damaged = try await installer.verifyOriginals(plan, at: directory, staging: first)
        XCTAssertEqual(damaged.invalidFiles, ["bin/steam_api64.dll"])
    }
    func testSteamStubNeedsOwnedRuntimeAndNoAPIGameStillValidates() async throws {
        for stub in [false, true] {
            let bytes = pe(section: stub ? ".bind" : ".text")
            let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
            let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
            let plan = try await installer.resolve(), directory = try temporaryDirectory()
            try await installer.download(plan, to: directory) { _ in }
            do {
                let receipt = try await installer.postInstall(plan, at: directory)
                XCTAssertFalse(stub)
                _ = try await installer.validate(plan, at: directory, staging: receipt)
            } catch { XCTAssertTrue(stub) }
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Game.exe")), bytes)
        }
    }
    func testPreparationRetryAndRepairPreserveCustomSettingsOriginalsAndSaves() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("bin/steam_api64.dll", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let staging = try await installer.postInstall(plan, at: directory)
        let settings = directory.appendingPathComponent("bin/steam_settings")
        let main = "; per-game connectivity\r\n[main::connectivity]\r\noffline=0\r\ndisable_networking=0\r\ncustom_connectivity=keep\r\n[main::overlay]\r\nenable_experimental_overlay=1\r\n"
        try Data(main.utf8).write(to: settings.appendingPathComponent("configs.main.ini"))
        for name in ["user", "app"] {
            let path = settings.appendingPathComponent("configs.\(name).ini")
            var original = try Data(contentsOf: path)
            original.append(contentsOf: "\n; keep this section\n[\(name)::custom]\noption=keep\n".utf8)
            try original.write(to: path)
        }
        let save = directory.appendingPathComponent("player.sav"), saved = Data("player progress".utf8)
        try saved.write(to: save)
        var previous: [String: Data] = [:]
        for attempt in 0..<2 {
            if attempt == 1 {
                try FileManager.default.removeItem(at: directory.appendingPathComponent("Game.exe"))
                try await installer.repair(plan, at: directory, staging: staging) { _ in }
            }
            let prepared = try await installer.postInstall(plan, at: directory)
            XCTAssertEqual(prepared, staging)
            _ = try await installer.validate(plan, at: directory, staging: prepared)
            for name in ["main", "user", "app"] {
                let data = try Data(contentsOf: settings.appendingPathComponent("configs.\(name).ini"))
                if attempt == 1 { XCTAssertEqual(data, previous[name]) }
                previous[name] = data
                if name != "main" {
                    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("; keep this section\n[\(name)::custom]\noption=keep\n"))
                }
            }
            let expected = main.replacingOccurrences(of: "offline=0", with: "offline=1")
                .replacingOccurrences(of: "disable_networking=0", with: "disable_networking=1")
                .replacingOccurrences(of: "[main::overlay]", with: "disable_lan_only=0\r\n[main::overlay]")
            XCTAssertEqual(previous["main"], Data(expected.utf8))
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("bin/steam_api64.dll.orig")), bytes)
            XCTAssertEqual(try Data(contentsOf: save), saved)
        }
    }
    private func prerequisiteFixture(tools: RecipeTools) async throws -> (SteamInstaller, InstallPlan, URL, GameBottle) {
        let game = SourceGameRecord(id: .init(source: "steam", value: "8870"), title: "BioShock Infinite")
        let info = AppInfo(appID: 8870, name: game.title, depots: [.init(id: 8871, manifestGID: 1)], launches: [.init(id: "0", executable: "Game.exe")])
        let data = pe(), cab = Data("fixture cabinet".utf8)
        let paths = try SteamRecipes.steps(for: game.id, version: 2).map(\.executable)
        let files = [file("Game.exe", data)] + paths.map { file($0, data) } + [file("Binaries/Prerequisites/directx_Jun2010_redist/runtime.cab", cab)]
        let content = ResolvedSteamContent(app: info, manifests: [manifest(files, depotID: 8871, gid: 1)], entitlements: .init(appIDs: [8870], depotIDs: [8871]))
        let backend = FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: data)): data, Data(Insecure.SHA1.hash(data: cab)): cab])
        let installer = SteamInstaller(game: game, backend: backend, runtimeTools: tools)
        let plan = try await installer.resolve(), root = try temporaryDirectory()
        try await installer.download(plan, to: root) { _ in }
        return (installer, plan, root, .init(gameID: game.id, name: "playden-steam-8870", ownershipToken: UUID()))
    }
    func testPrerequisitesIgnoreUnrelatedLinksAndRecheckAfterRuntimeAwait() async throws {
        let tools = RecipeTools(), (installer, plan, root, bottle) = try await prerequisiteFixture(tools: tools)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("unrelated").path, withDestinationPath: "missing")
        try await installer.preparePrerequisites(plan, at: root, in: bottle)
        let replacement = root.appendingPathExtension("previous")
        addTeardownBlock { try? FileManager.default.removeItem(at: replacement) }
        await tools.setDuringReady {
            try FileManager.default.moveItem(at: root, to: replacement)
            try FileManager.default.copyItem(at: replacement, to: root)
        }
        do { try await installer.preparePrerequisites(plan, at: root, in: bottle); XCTFail("Replaced directory accepted after readiness await") } catch {}
    }

    func testPinnedRecipeRetriesFromFailedPrerequisiteWithoutTouchingGameFiles() async throws {
        let tools = RecipeTools(), (installer, plan, root, bottle) = try await prerequisiteFixture(tools: tools)
        XCTAssertEqual(plan.recipeVersion, 2)
        let restored = try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(plan))
        let save = root.appendingPathComponent("player.sav"); try Data("progress".utf8).write(to: save)
        await tools.failOnce("bioshock-vc2010-x86-1")
        do { try await installer.preparePrerequisites(restored, at: root, in: bottle); XCTFail("Prerequisite failure ignored") } catch {}
        try await installer.preparePrerequisites(restored, at: root, in: bottle)
        try await installer.preparePrerequisites(restored, at: root, in: bottle)
        let calls = await tools.calls
        XCTAssertEqual(calls, ["bioshock-vc2008-x86-1", "bioshock-vc2010-x86-1", "bioshock-vc2010-x86-1", "bioshock-directx-jun2010-1"])
        XCTAssertEqual(try Data(contentsOf: save), Data("progress".utf8))
        let intact = try await installer.verifyOriginals(plan, at: root, staging: nil); XCTAssertTrue(intact.isValid)
    }
    func testRecipeRejectsDamagedInputsAndUnownedBottleBeforeExecuting() async throws {
        let tools = RecipeTools(), (installer, plan, root, bottle) = try await prerequisiteFixture(tools: tools)
        let wrong = GameBottle(gameID: .init(source: "steam", value: "other"), name: bottle.name, ownershipToken: bottle.ownershipToken)
        do { try await installer.preparePrerequisites(plan, at: root, in: wrong); XCTFail("Foreign game accepted") } catch {}
        try Data("damaged".utf8).write(to: root.appendingPathComponent("Binaries/Prerequisites/vcredist_x86_vs2008sp1.exe"))
        do { try await installer.preparePrerequisites(plan, at: root, in: bottle); XCTFail("Damaged prerequisite executed") } catch {}
        let calls = await tools.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testRecipeVersionOneRemainsPinnedAndMissingPrerequisitesBlockNewResolution() async throws {
        let id = GameID(source: "steam", value: "8870"), game = SourceGameRecord(id: id, title: "BioShock Infinite")
        let info = AppInfo(appID: 8870, name: game.title, depots: [.init(id: 8871, manifestGID: 1)], launches: [.init(id: "0", executable: "Game.exe")])
        let files = [manifest([file("Game.exe", pe())], depotID: 8871, gid: 1)]
        XCTAssertThrowsError(try SteamPlanBuilder.build(game: game, app: info, manifests: files, ownedApps: [8870]))
        let legacy = try SteamPlanBuilder.build(game: game, app: info, manifests: files, ownedApps: [8870], recipeVersion: 1)
        XCTAssertNoThrow(try SteamPlanBuilder.payload(legacy, for: id))
        XCTAssertTrue(try SteamRecipes.steps(for: id, version: legacy.recipeVersion).isEmpty)
        XCTAssertThrowsError(try SteamRecipes.steps(for: id, version: 3))
        XCTAssertThrowsError(try SteamRecipes.steps(for: .init(source: "steam", value: "100"), version: 2))
    }
    func testSteamStubPreparationReplayRepairAndSavedReceiptKeepOriginalAndSaves() async throws {
        for hasAPI in [false, true] {
            let original = pe(section: ".bind"), unpacked = pe(), tools = FixtureUnpackingTools(output: unpacked)
            let files = [file("Game.exe", original)] + (hasAPI ? [file("steam_api64.dll", pe())] : [])
            let content = ResolvedSteamContent(app: app(), manifests: [manifest(files)], entitlements: .init(appIDs: [100], depotIDs: [101]))
            let backend = FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: original)): original, Data(Insecure.SHA1.hash(data: unpacked)): unpacked])
            let installer = SteamInstaller(game: game, backend: backend, runtimeTools: tools)
            let plan = try await installer.resolve(), directory = try temporaryDirectory()
            let bottle = GameBottle(gameID: game.id, name: "playden-steam-100", ownershipToken: UUID())
            try await installer.download(plan, to: directory) { _ in }
            let save = directory.appendingPathComponent("player.sav")
            try Data("keep progress".utf8).write(to: save)
            let first = try await installer.postInstall(plan, at: directory, in: bottle)
            XCTAssertEqual(first.version, 2)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Game.exe.orig")), original)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Game.exe")), unpacked)
            let serialized = try JSONEncoder().encode(first)
            let restored = try JSONDecoder().decode(InstallStaging.self, from: serialized)
            _ = try await installer.validate(plan, at: directory, staging: restored)
            let replay = try await installer.postInstall(plan, at: directory, in: bottle)
            XCTAssertEqual(first, replay)
            try Data("damaged".utf8).write(to: directory.appendingPathComponent("Game.exe.orig"))
            try Data("damaged".utf8).write(to: directory.appendingPathComponent("Game.exe"))
            try await installer.repair(plan, at: directory, staging: restored) { _ in }
            let repaired = try await installer.postInstall(plan, at: directory, in: bottle)
            _ = try await installer.validate(plan, at: directory, staging: repaired)
            XCTAssertEqual(repaired, first)
            XCTAssertEqual(try Data(contentsOf: save), Data("keep progress".utf8))
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Game.exe.orig")), original)
        }
    }
    func testFailedOrInvalidUnpackingDoesNotReplaceOriginalAndCanResumeBeforeReceipt() async throws {
        for output in [Data("invalid PE".utf8), pe(section: ".bind")] {
            let original = pe(section: ".bind"), tools = FixtureUnpackingTools(output: output)
            let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", original)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
            let backend = FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: original)): original])
            let installer = SteamInstaller(game: game, backend: backend, runtimeTools: tools)
            let plan = try await installer.resolve(), directory = try temporaryDirectory()
            let bottle = GameBottle(gameID: game.id, name: "playden-steam-100", ownershipToken: UUID())
            try await installer.download(plan, to: directory) { _ in }
            do { _ = try await installer.postInstall(plan, at: directory, in: bottle); XCTFail("Invalid unpacked output accepted") } catch {}
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Game.exe")), original)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Game.exe.orig")), original)
            await tools.setOutput(pe())
            let recovered = try await installer.postInstall(plan, at: directory, in: bottle)
            _ = try await installer.validate(plan, at: directory, staging: recovered)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Game.exe.orig")), original)
        }
    }
    func testRealSteamlessOnDisposableBioShockOriginalWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["PLAYDEN_STEAMLESS_ORIGINAL"] else {
            throw XCTSkip("Opt in with an original SteamStub executable; only a disposable copy and bottle are used")
        }
        let original = URL(fileURLWithPath: path), before = try Data(contentsOf: original)
        XCTAssertTrue(try PEInspector.inspect(original).requiresSteamStubRuntime)
        let id = GameID(source: "probe", value: UUID().uuidString.lowercased())
        let bottle = GameBottle(gameID: id, name: CrossOverGameBottles.name(for: id), ownershipToken: UUID())
        let manager = CrossOverGameBottles()
        do {
            try await manager.prepare(bottle)
            let unpacked = try await SteamUnpacking.unpack(original, in: bottle, tools: CrossOverTools(manager: manager))
            XCTAssertNotEqual(unpacked, before)
            XCTAssertEqual(try Data(contentsOf: original), before)
            let output = try temporaryDirectory().appendingPathComponent("unpacked.exe")
            try unpacked.write(to: output)
            XCTAssertFalse(try PEInspector.inspect(output).requiresSteamStubRuntime)
            XCTAssertNotNil(try PEInspector.inspect(output).entryPointSection)
            try await manager.remove(bottle)
        } catch { try? await manager.remove(bottle); throw error }
    }
    func testRepairRestoresMissingContentAndOriginalBackupsWithoutReplacingSaves() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("steam_api64.dll", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let staging = try await installer.postInstall(plan, at: directory)
        let replacement = try Data(contentsOf: directory.appendingPathComponent("steam_api64.dll"))
        let save = directory.appendingPathComponent("player.sav")
        try Data("keep this save".utf8).write(to: save)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Game.exe"))
        try Data("short".utf8).write(to: directory.appendingPathComponent("steam_api64.dll.orig"))
        try await installer.repair(plan, at: directory, staging: staging) { _ in }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Game.exe")), bytes)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("steam_api64.dll.orig")), bytes)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("steam_api64.dll")), replacement)
        XCTAssertEqual(try Data(contentsOf: save), Data("keep this save".utf8))
        try Data("damaged replacement".utf8).write(to: directory.appendingPathComponent("steam_api64.dll"))
        let repaired = try await installer.postInstall(plan, at: directory)
        _ = try await installer.validate(plan, at: directory, staging: repaired)
        XCTAssertEqual(repaired, staging)
    }
    func testApplyRuntimeOptionsWritesOverlayIniPreservingOtherSectionsAndFiles() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("steam_api64.dll", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        _ = try await installer.postInstall(plan, at: directory)
        let settings = directory.appendingPathComponent("steam_settings")
        let overlay = settings.appendingPathComponent("configs.overlay.ini")
        try Data("[overlay::foo]\nbar=1\n".utf8).write(to: overlay)
        let appBefore = try Data(contentsOf: settings.appendingPathComponent("configs.app.ini"))
        try await installer.applyRuntimeOptions(["steam.overlay": "1"], plan: plan, at: directory)
        var text = try String(contentsOf: overlay, encoding: .utf8)
        XCTAssertTrue(text.contains("enable_experimental_overlay=1"))
        XCTAssertTrue(text.contains("[overlay::foo]"))
        XCTAssertTrue(text.contains("bar=1"))
        try await installer.applyRuntimeOptions(["steam.overlay": "0"], plan: plan, at: directory)
        text = try String(contentsOf: overlay, encoding: .utf8)
        XCTAssertTrue(text.contains("enable_experimental_overlay=0"))
        XCTAssertTrue(text.contains("[overlay::foo]"))
        XCTAssertTrue(text.contains("bar=1"))
        XCTAssertEqual(try Data(contentsOf: settings.appendingPathComponent("configs.app.ini")), appBefore)
    }
    func testApplyRuntimeOptionsRejectsSymlinkedSteamSettings() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("steam_api64.dll", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        _ = try await installer.postInstall(plan, at: directory)
        let settings = directory.appendingPathComponent("steam_settings")
        let elsewhere = directory.deletingLastPathComponent().appendingPathComponent("PlaydenSteamSettings-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: settings, to: elsewhere)
        addTeardownBlock { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: elsewhere)
        do {
            try await installer.applyRuntimeOptions(["steam.overlay": "1"], plan: plan, at: directory)
            XCTFail("Symlinked steam_settings accepted")
        } catch {}
    }
    func testApplyRuntimeOptionsIgnoresAnUnrelatedSymlinkElsewhereInTheInstallDirectory() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("steam_api64.dll", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        _ = try await installer.postInstall(plan, at: directory)
        let elsewhere = directory.deletingLastPathComponent().appendingPathComponent("PlaydenUnrelated-\(UUID().uuidString)")
        try Data("x".utf8).write(to: elsewhere)
        addTeardownBlock { try? FileManager.default.removeItem(at: elsewhere) }
        // A symlink that sits inside the install directory but away from the API/steam_settings/ini
        // path used to fail because of a full recursive scan; the targeted check should ignore it.
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("unrelated-link"), withDestinationURL: elsewhere)
        try await installer.applyRuntimeOptions(["steam.overlay": "1"], plan: plan, at: directory)
        let overlay = directory.appendingPathComponent("steam_settings/configs.overlay.ini")
        XCTAssertTrue(try String(contentsOf: overlay, encoding: .utf8).contains("enable_experimental_overlay=1"))
    }
    func testApplyRuntimeOptionsSkipsRewritingTheIniWhenTheValueIsUnchanged() async throws {
        let bytes = pe()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes), file("steam_api64.dll", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        _ = try await installer.postInstall(plan, at: directory)
        try await installer.applyRuntimeOptions(["steam.overlay": "1"], plan: plan, at: directory)
        let overlay = directory.appendingPathComponent("steam_settings/configs.overlay.ini")
        let before = try Data(contentsOf: overlay)
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: overlay.path)[.modificationDate] as? Date
        try await installer.applyRuntimeOptions(["steam.overlay": "1"], plan: plan, at: directory)
        let after = try Data(contentsOf: overlay)
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: overlay.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        XCTAssertEqual(modifiedBefore, modifiedAfter)
        // A changed value still rewrites the file.
        try await installer.applyRuntimeOptions(["steam.overlay": "0"], plan: plan, at: directory)
        let changed = try Data(contentsOf: overlay)
        XCTAssertNotEqual(changed, before)
        XCTAssertTrue(try String(contentsOf: overlay, encoding: .utf8).contains("enable_experimental_overlay=0"))
    }
    func testApplyRuntimeOptionsIsNoOpWithoutStagedSteamAPI() async throws {
        let bytes = Data("test".utf8)
        let content = ResolvedSteamContent(app: app(), manifests: [manifest([file("Game.exe", bytes)])], entitlements: .init(appIDs: [100], depotIDs: [101]))
        let installer = SteamInstaller(game: game, backend: FixtureContentBackend(content: content, chunks: [Data(Insecure.SHA1.hash(data: bytes)): bytes]))
        let plan = try await installer.resolve(), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        try await installer.applyRuntimeOptions(["steam.overlay": "1"], plan: plan, at: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("steam_settings").path))
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PlaydenInstaller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func pe(section: String = ".text") -> Data {
        var data = Data(repeating: 0, count: 1024)
        func put(_ value: UInt32, at offset: Int, count: Int = 4) {
            for i in 0..<count { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        data[0] = 0x4d; data[1] = 0x5a; put(0x80, at: 0x3c); data[0x80] = 0x50; data[0x81] = 0x45
        put(0x8664, at: 0x84, count: 2); put(1, at: 0x86, count: 2); put(0xf0, at: 0x94, count: 2)
        put(0x20b, at: 0x98, count: 2); put(0x1000, at: 0xa8)
        for (i, byte) in section.utf8.enumerated() { data[0x188 + i] = byte }
        put(0x1000, at: 0x190); put(0x1000, at: 0x194); put(0x200, at: 0x198)
        return data
    }
}
private actor RecipeTools: RuntimeToolRunning {
    var calls: [String] = []
    var completed: [String: Data] = [:]
    var fail: String?
    var duringReady: (@Sendable () throws -> Void)?
    func setDuringReady(_ action: @escaping @Sendable () throws -> Void) { duringReady = action }
    func failOnce(_ id: String) { fail = id }
    func runTool(executable: URL, arguments: [String], in bottle: GameBottle) async throws { XCTFail("Prerequisite context was lost") }
    func prerequisiteReady(_ prerequisite: RuntimePrerequisite, in bottle: GameBottle) async throws -> Bool { try duringReady?(); return completed[prerequisite.id] == prerequisite.fingerprint }
    func preparePrerequisite(_ prerequisite: RuntimePrerequisite, executable: URL, in bottle: GameBottle) async throws {
        calls.append(prerequisite.id)
        XCTAssertTrue(executable.path.contains("Playden-prerequisites-"))
        if prerequisite.id.contains("directx") { XCTAssertTrue(FileManager.default.fileExists(atPath: executable.deletingLastPathComponent().appendingPathComponent("runtime.cab").path)) }
        if fail == prerequisite.id { fail = nil; throw SourceFailure.unavailable }
        completed[prerequisite.id] = prerequisite.fingerprint
    }
}
private actor FixtureUnpackingTools: RuntimeToolRunning {
    var output: Data
    let duringRun: @Sendable () throws -> Void
    init(output: Data, duringRun: @escaping @Sendable () throws -> Void = {}) { self.output = output; self.duringRun = duringRun }
    func setOutput(_ value: Data) { output = value }
    func runTool(executable: URL, arguments: [String], in bottle: GameBottle) async throws {
        try duringRun()
        XCTAssertEqual(executable.lastPathComponent, "Steamless.CLI.exe")
        let input = String(arguments.last!.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
        try output.write(to: URL(fileURLWithPath: input + ".unpacked.exe"))
    }
}
private struct FixtureContentBackend: SteamInstallBackend {
    let content: ResolvedSteamContent
    let chunks: [Data: Data]
    var diagnostics: SteamPerformanceDiagnostics? = nil
    func resolve(appID: UInt32, platform: GamePlatform) async throws -> ResolvedSteamContent { content }
    func repair(_ payload: SteamInstallPayload, using repair: SteamRepairDownload, to directory: URL,
                progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        for manifest in payload.manifests {
            let download = repair.downloader(for: manifest, at: directory, diagnostics: diagnostics)
            try await download.download(manifest: repair.subset(of: manifest)) { chunk in
                guard let data = chunks[chunk.sha] else { throw SourceFailure.unavailable }
                try chunk.validate(data)
                return data
            }
        }
    }

    func download(_ payload: SteamInstallPayload, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        for manifest in payload.manifests {
            try await ResumableDepotDownload(destination: directory, diagnostics: diagnostics).download(manifest: manifest) { chunk in
                guard let data = chunks[chunk.sha] else { throw SourceFailure.unavailable }
                try chunk.validate(data)
                return data
            }
        }
    }
}

private final class VerificationSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InstallFileVerification] = []
    func append(_ value: InstallFileVerification) { lock.withLock { storage.append(value) } }
    var values: [InstallFileVerification] { lock.withLock { storage } }
}

private final class PreparationSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InstallPreparationProgress] = []
    func append(_ value: InstallPreparationProgress) { lock.withLock { storage.append(value) } }
    var values: [InstallPreparationProgress] { lock.withLock { storage } }
}

private actor ReplacingUnpackWorkspace: RuntimeToolRunning {
    let output: Data
    var work: URL?
    var moved: URL?
    init(output: Data) { self.output = output }
    func runTool(executable: URL, arguments: [String], in bottle: GameBottle) async throws {
        let input = URL(fileURLWithPath: String(arguments.last!.dropFirst(2)).replacingOccurrences(of: "\\", with: "/"))
        let root = input.deletingLastPathComponent(), old = root.appendingPathExtension("moved")
        work = root; moved = old
        try FileManager.default.moveItem(at: root, to: old)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try output.write(to: URL(fileURLWithPath: input.path + ".unpacked.exe"))
    }
    func cleanup() {
        for url in [work, moved].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
    }
}
