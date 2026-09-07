import XCTest
import CryptoKit
import Domain
import SteamCore
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
    func testSteamStubStopsBeforeStagingAndNoAPIGameStillValidates() async throws {
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
