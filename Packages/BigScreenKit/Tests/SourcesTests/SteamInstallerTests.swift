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
        XCTAssertThrowsError(try plan([file("Game.exe")], app: app(launches: [.init(id: "0", executable: "Game.exe"), .init(id: "1", executable: "Game.exe")])))
        XCTAssertThrowsError(try plan([file("Game.exe")], app: app(launches: [.init(id: "0", executable: "../Game.exe")])))
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
        return (installer, plan, root, .init(gameID: game.id, name: "gn-steam-8870", ownershipToken: UUID()))
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
            let bottle = GameBottle(gameID: game.id, name: "gn-steam-100", ownershipToken: UUID())
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
            let bottle = GameBottle(gameID: game.id, name: "gn-steam-100", ownershipToken: UUID())
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
        guard let path = ProcessInfo.processInfo.environment["BIGSCREEN_STEAMLESS_ORIGINAL"] else {
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
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BigScreenInstaller-\(UUID().uuidString)")
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
    func failOnce(_ id: String) { fail = id }
    func runTool(executable: URL, arguments: [String], in bottle: GameBottle) async throws { XCTFail("Prerequisite context was lost") }
    func prerequisiteReady(_ prerequisite: RuntimePrerequisite, in bottle: GameBottle) async throws -> Bool { completed[prerequisite.id] == prerequisite.fingerprint }
    func preparePrerequisite(_ prerequisite: RuntimePrerequisite, executable: URL, in bottle: GameBottle) async throws {
        calls.append(prerequisite.id)
        XCTAssertTrue(executable.path.contains("BigScreen-prerequisites-"))
        if prerequisite.id.contains("directx") { XCTAssertTrue(FileManager.default.fileExists(atPath: executable.deletingLastPathComponent().appendingPathComponent("runtime.cab").path)) }
        if fail == prerequisite.id { fail = nil; throw SourceFailure.unavailable }
        completed[prerequisite.id] = prerequisite.fingerprint
    }
}
private actor FixtureUnpackingTools: RuntimeToolRunning {
    var output: Data
    init(output: Data) { self.output = output }
    func setOutput(_ value: Data) { output = value }
    func runTool(executable: URL, arguments: [String], in bottle: GameBottle) async throws {
        XCTAssertEqual(executable.lastPathComponent, "Steamless.CLI.exe")
        let input = String(arguments.last!.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
        try output.write(to: URL(fileURLWithPath: input + ".unpacked.exe"))
    }
}
private struct FixtureContentBackend: SteamInstallBackend {
    let content: ResolvedSteamContent
    let chunks: [Data: Data]
    func resolve(appID: UInt32) async throws -> ResolvedSteamContent { content }
    func download(_ payload: SteamInstallPayload, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        for manifest in payload.manifests {
            try await ResumableDepotDownload(destination: directory).download(manifest: manifest) { chunk in
                guard let data = chunks[chunk.sha] else { throw SourceFailure.unavailable }
                return data
            }
        }
    }
}
