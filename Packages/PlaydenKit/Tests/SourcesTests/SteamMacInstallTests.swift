import XCTest
import CryptoKit
import Domain
import SteamCore
@testable import Sources

/// Signing rewrites the bundle's executable and seal, as `codesign --force --sign -` does.
private actor FixtureSigner: CodeSigning {
    var signed: [String] = [], verified: [String] = []
    let afterSign: @Sendable () throws -> Void
    init(afterSign: @escaping @Sendable () throws -> Void = {}) { self.afterSign = afterSign }
    nonisolated func sign(_ bundle: URL) async throws {
        let executable = bundle.appendingPathComponent("Contents/MacOS/Game")
        var data = try Data(contentsOf: executable); data.append(Data("adhoc".utf8)); try data.write(to: executable)
        try Data("sealed".utf8).write(to: bundle.appendingPathComponent("Contents/_CodeSignature/CodeResources"))
        await record(sign: bundle.lastPathComponent)
        try afterSign()
    }
    nonisolated func verify(_ bundle: URL) async throws { await record(verify: bundle.lastPathComponent) }
    func record(sign: String? = nil, verify: String? = nil) { if let sign { signed.append(sign) }; if let verify { verified.append(verify) } }
}
private struct MacBackend: SteamInstallBackend {
    let content: ResolvedSteamContent
    let chunks: [Data: Data]
    func resolve(appID: UInt32, platform: GamePlatform) async throws -> ResolvedSteamContent { content }
    func download(_ payload: SteamInstallPayload, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        for manifest in payload.manifests {
            try await ResumableDepotDownload(destination: directory).download(manifest: manifest) { chunk in
                guard let data = chunks[chunk.sha] else { throw SourceFailure.unavailable }
                try chunk.validate(data)
                return data
            }
        }
    }
}

final class SteamMacInstallTests: XCTestCase {
    private let game = SourceGameRecord(id: GameID(source: "steam", value: "100"), title: "Fixture")
    private let machO = Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(repeating: 1, count: 64)
    private let info = Data("""
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Game</string>\
        <key>CFBundleIdentifier</key><string>com.example.fixture</string></dict></plist>
        """.utf8)
    private func file(_ path: String, _ bytes: Data, executable: Bool = false) -> DepotManifest.File {
        let sha = Data(Insecure.SHA1.hash(data: bytes))
        return .init(path: path, size: UInt64(bytes.count), flags: executable ? 32 : 0,
                     chunks: [.init(sha: sha, offset: 0, compressedSize: UInt32(bytes.count), uncompressedSize: UInt32(bytes.count))], contentSHA1: sha)
    }
    private func manifest(_ files: [DepotManifest.File], depot: UInt32) -> DepotManifest {
        .init(depotID: depot, gid: UInt64(depot), files: files, totalSize: files.reduce(0) { $0 + $1.size })
    }
    private func app() -> AppInfo {
        AppInfo(appID: 100, name: "Fixture", depots: [
            DepotInfo(id: 101, osList: "windows", manifestGID: 101), DepotInfo(id: 102, osList: "macos", manifestGID: 102),
            DepotInfo(id: 103, manifestGID: 103),
        ], launches: [
            AppLaunch(id: "0", executable: "Game.exe", osList: "windows"),
            AppLaunch(id: "1", executable: "Game.app/Contents/MacOS/Game", arguments: "-screen-fullscreen 1 \"two words\"", osList: "macos"),
        ])
    }
    private var macFiles: [DepotManifest.File] {
        [file("Game.app/Contents/Info.plist", info), file("Game.app/Contents/MacOS/Game", machO, executable: true),
         file("Game.app/Contents/Frameworks/libsteam_api.dylib", machO + Data("valve".utf8)),
         file("Game.app/Contents/_CodeSignature/CodeResources", Data("original seal".utf8))]
    }
    private var chunks: [Data: Data] {
        Dictionary([info, machO, machO + Data("valve".utf8), Data("original seal".utf8)].map { ($0.sha1, $0) }) { first, _ in first }
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SteamMac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMacSpaceBudgetIncludesLibraryAndSignedOriginalsOnly() throws {
        let files = macFiles + [file("chmod-only", Data(repeating: 2, count: 800), executable: true)]
        let shared = file("asset", Data(repeating: 3, count: 900))
        let plan = try SteamPlanBuilder.build(game: game, app: app(), manifests: [manifest(files, depot: 102), manifest([shared], depot: 103)],
            ownedApps: [100], platform: .macOS)
        let backups = macFiles.filter { !$0.path.hasSuffix("Info.plist") }.reduce(Int64(0)) { $0 + Int64($1.size) }
        XCTAssertEqual(plan.estimate.requiredBytes, plan.estimate.installedBytes + backups + 256 * 1024 * 1024)
        let decoded = try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(try SteamPlanBuilder.payload(decoded, for: game.id).version, 2)
    }
    func testMacSigningRechecksInstallationAfterAwait() async throws {
        let directory = try temporaryDirectory(), moved = directory.appendingPathExtension("moved")
        addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
        let signer = FixtureSigner(afterSign: {
            try FileManager.default.moveItem(at: directory, to: moved)
            try FileManager.default.copyItem(at: moved, to: directory)
        })
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(macFiles, depot: 102)], entitlements: .init(appIDs: [100], depotIDs: [102]))
        let installer = SteamInstaller(game: game, backend: MacBackend(content: content, chunks: chunks), emulatorSaves: try temporaryDirectory(), codeSigner: signer)
        let plan = try await installer.resolve(platform: .macOS)
        try await installer.download(plan, to: directory) { _ in }
        do { _ = try await installer.postInstall(plan, at: directory); XCTFail("Replaced installation accepted after signing") } catch {}
    }

    func testMacPreparationRejectsLinkedSigningSettingsAndSaveDestinations() async throws {
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(macFiles, depot: 102)], entitlements: .init(appIDs: [100], depotIDs: [102]))
        let backend = MacBackend(content: content, chunks: chunks)
        for leaf in ["Game.app/Contents/MacOS/Game", "Game.app/Contents/_CodeSignature", ".playden-originals/Game.app/Contents/MacOS", ".playden-steam/steam_settings"] {
            let saves = try temporaryDirectory(), directory = try temporaryDirectory(), outside = try temporaryDirectory()
            let installer = SteamInstaller(game: game, backend: backend, emulatorSaves: saves, codeSigner: FixtureSigner())
            let plan = try await installer.resolve(platform: .macOS)
            try await installer.download(plan, to: directory) { _ in }
            _ = try await installer.postInstall(plan, at: directory)
            let target = directory.appendingPathComponent(leaf), moved = outside.appendingPathComponent("keep")
            try FileManager.default.moveItem(at: target, to: moved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
            let signer = FixtureSigner()
            let restarted = SteamInstaller(game: game, backend: backend, emulatorSaves: saves, codeSigner: signer)
            do { _ = try await restarted.postInstall(plan, at: directory); XCTFail("Linked Mac destination accepted: " + leaf) } catch {}
            let signed = await signer.signed; XCTAssertTrue(signed.isEmpty)
        }
        let directory = try temporaryDirectory(), saves = try temporaryDirectory(), outside = try temporaryDirectory()
        try FileManager.default.createSymbolicLink(at: saves.appendingPathComponent("100"), withDestinationURL: outside)
        let installer = SteamInstaller(game: game, backend: backend, emulatorSaves: saves, codeSigner: FixtureSigner())
        let plan = try await installer.resolve(platform: .macOS)
        try await installer.download(plan, to: directory) { _ in }
        do { _ = try await installer.postInstall(plan, at: directory); XCTFail("Linked emulator save directory accepted") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testMacSigningRejectsInfoPlistExecutableEscape() async throws {
        let escaping = Data(String(decoding: info, as: UTF8.self).replacingOccurrences(of: "<string>Game</string>", with: "<string>../Game</string>").utf8)
        let files = macFiles.map { $0.path.hasSuffix("Info.plist") ? file($0.path, escaping) : $0 }
        var chunks = self.chunks; chunks[escaping.sha1] = escaping
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(files, depot: 102)], entitlements: .init(appIDs: [100], depotIDs: [102]))
        let signer = FixtureSigner(), directory = try temporaryDirectory()
        let installer = SteamInstaller(game: game, backend: MacBackend(content: content, chunks: chunks), emulatorSaves: try temporaryDirectory(), codeSigner: signer)
        let plan = try await installer.resolve(platform: .macOS)
        try await installer.download(plan, to: directory) { _ in }
        do { _ = try await installer.postInstall(plan, at: directory); XCTFail("Escaping signing executable accepted") } catch {}
        let signed = await signer.signed; XCTAssertTrue(signed.isEmpty)
    }

    func testMacManifestDiscoveryPreservesUnrelatedLibraryAndFrameworkLinks() async throws {
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(macFiles, depot: 102)], entitlements: .init(appIDs: [100], depotIDs: [102]))
        let installer = SteamInstaller(game: game, backend: MacBackend(content: content, chunks: chunks), emulatorSaves: try temporaryDirectory(), codeSigner: FixtureSigner())
        let plan = try await installer.resolve(platform: .macOS), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let framework = directory.appendingPathComponent("Game.app/Contents/Frameworks/Extra.framework")
        try FileManager.default.createDirectory(at: framework.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        let extra = framework.appendingPathComponent("Versions/A/libsteam_api.dylib")
        try Data("unrelated library".utf8).write(to: extra)
        let staging = try await installer.postInstall(plan, at: directory)
        _ = try await installer.validate(plan, at: directory, staging: staging)
        XCTAssertEqual(try Data(contentsOf: extra), Data("unrelated library".utf8))
    }

    func testUnsignedMacStagesKeepExecutableReceiptsAcrossPreparationRetry() async throws {
        let files = macFiles.filter { !$0.path.contains("_CodeSignature") && !$0.path.contains("libsteam_api") }
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(files, depot: 102)], entitlements: .init(appIDs: [100], depotIDs: [102]))
        let backend = MacBackend(content: content, chunks: chunks)
        let initial = SteamInstaller(game: game, backend: backend)
        let plan = try await initial.resolve(platform: .macOS), directory = try temporaryDirectory()
        try await initial.download(plan, to: directory) { _ in }
        let diagnostics = SteamPerformanceDiagnostics()
        for _ in 0..<2 {
            let restarted = SteamInstaller(game: game, backend: backend, diagnostics: diagnostics)
            let check = try await restarted.verifyOriginals(plan, at: directory, staging: nil)
            XCTAssertTrue(check.isValid)
            let staging = try await restarted.postInstall(plan, at: directory)
            _ = try await restarted.validate(plan, at: directory, staging: staging)
        }
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 0, "Redundant chmod must not invalidate executable receipts")
    }

    func testInterruptedMacOriginalCopyRecoversBeforePreparationReceipt() async throws {
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(macFiles, depot: 102)], entitlements: .init(appIDs: [100], depotIDs: [102]))
        let installer = SteamInstaller(game: game, backend: MacBackend(content: content, chunks: chunks),
            emulatorSaves: try temporaryDirectory(), codeSigner: FixtureSigner())
        let plan = try await installer.resolve(platform: .macOS), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let backup = directory.appendingPathComponent(".playden-originals/Game.app/Contents/MacOS/Game")
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try machO.prefix(8).write(to: backup)
        let staging = try await installer.postInstall(plan, at: directory)
        XCTAssertEqual(try Data(contentsOf: backup), machO)
        _ = try await installer.validate(plan, at: directory, staging: staging)
    }

    func testSignedMacValidationHashesOnlyKeptOriginalsAcrossRestart() async throws {
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(macFiles, depot: 102)], entitlements: .init(appIDs: [100], depotIDs: [102]))
        let backend = MacBackend(content: content, chunks: chunks), diagnostics = SteamPerformanceDiagnostics(), signer = FixtureSigner()
        let installer = SteamInstaller(game: game, backend: backend, emulatorSaves: try temporaryDirectory(), codeSigner: signer, diagnostics: diagnostics)
        let plan = try await installer.resolve(platform: .macOS), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let staging = try await installer.postInstall(plan, at: directory)
        XCTAssertEqual(diagnostics.snapshot()[.sha1].bytes, 0)
        for _ in 0..<2 {
            let restarted = SteamInstaller(game: game, backend: backend, codeSigner: signer, diagnostics: diagnostics)
            _ = try await restarted.validate(plan, at: directory, staging: staging)
        }
        XCTAssertEqual(diagnostics.snapshot()[.sha1].bytes, 308, "Each validation hashes only the 73-byte API, 68-byte executable and 13-byte seal originals")
        let verified = await signer.verified
        XCTAssertEqual(verified, ["Game.app", "Game.app"])
        let backup = directory.appendingPathComponent(".playden-originals/Game.app/Contents/MacOS/Game")
        try Data(repeating: 0, count: machO.count).write(to: backup)
        let broken = try await installer.verifyOriginals(plan, at: directory, staging: staging)
        XCTAssertEqual(broken.invalidFiles, ["Game.app/Contents/MacOS/Game"])
        do { _ = try await installer.postInstall(plan, at: directory); XCTFail("Damaged backup and signed executable are not original content") } catch {}
        try await installer.repair(plan, at: directory, staging: staging) { _ in }
        let repaired = try await installer.postInstall(plan, at: directory)
        _ = try await installer.validate(plan, at: directory, staging: repaired)
        XCTAssertEqual(try Data(contentsOf: backup), machO)
    }

    func testMissingMacExecutableFlagRestoresPermissionsWithoutReadingOrdinaryAssets() async throws {
        let files = [file("Game.app/Contents/Info.plist", info), file("Game.app/Contents/MacOS/Game", machO)]
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(files, depot: 102)], entitlements: .init(appIDs: [100], depotIDs: [102]))
        let diagnostics = SteamPerformanceDiagnostics(), installer = SteamInstaller(game: game, backend: MacBackend(content: content, chunks: chunks), diagnostics: diagnostics)
        let plan = try await installer.resolve(platform: .macOS), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        for _ in 0..<2 {
            let staging = try await installer.postInstall(plan, at: directory)
            _ = try await installer.validate(plan, at: directory, staging: staging)
        }
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 68, "Only the executable whose permissions changed needs refreshed metadata")
    }

    func testMacDiagnosticsIncludeNestedPreparationAndValidationWork() async throws {
        let diagnostics = SteamPerformanceDiagnostics()
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(macFiles, depot: 102)],
            entitlements: .init(appIDs: [100], depotIDs: [102]))
        let installer = SteamInstaller(game: game, backend: MacBackend(content: content, chunks: chunks),
            emulatorSaves: try temporaryDirectory(), codeSigner: FixtureSigner(), diagnostics: diagnostics)
        let plan = try await installer.resolve(platform: .macOS), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let staging = try await installer.postInstall(plan, at: directory)
        let prepared = diagnostics.snapshot()
        XCTAssertEqual(prepared[.preparation].count, 1)
        XCTAssertEqual(prepared[.emulatorPreparation].count, 1)
        XCTAssertGreaterThan(prepared[.sha256].bytes, 1024 * 1024)
        XCTAssertGreaterThan(prepared[.contentRead].bytes, prepared[.sha256].bytes)
        XCTAssertGreaterThan(prepared[.directoryWalk].count, 0)
        _ = try await installer.validate(plan, at: directory, staging: staging)
        let validated = diagnostics.snapshot()
        XCTAssertEqual(validated[.finalValidation].count, 1)
        XCTAssertGreaterThan(validated[.sha1].bytes, prepared[.sha1].bytes)
        XCTAssertGreaterThan(validated[.sha256].bytes, prepared[.sha256].bytes)
    }

    func testPlatformSelectsItsDepotsAndLaunchEntry() throws {
        let shared = manifest([file("shared.txt", Data("both".utf8))], depot: 103)
        let windows = try SteamPlanBuilder.build(game: game, app: app(), manifests: [manifest([file("Game.exe", machO)], depot: 101), shared], ownedApps: [100])
        XCTAssertEqual(windows.resolvedPlatform, .windows); XCTAssertNil(windows.platform, "Windows plans keep their existing encoding")
        XCTAssertEqual(Set(windows.manifestIDs.keys), ["101", "103"])
        let mac = try SteamPlanBuilder.build(game: game, app: app(), manifests: [manifest(macFiles, depot: 102), shared], ownedApps: [100], platform: .macOS)
        XCTAssertEqual(mac.platform, .macOS); XCTAssertEqual(Set(mac.manifestIDs.keys), ["102", "103"])
        XCTAssertEqual(mac.launchSpec.executableRelativePath, "Game.app")
        XCTAssertEqual(mac.launchSpec.arguments, ["-screen-fullscreen", "1", "two words"])
        XCTAssertEqual(try SteamPlanBuilder.payload(mac, for: game.id).platform, .macOS, "A saved Mac plan rebuilds as a Mac plan")
        let noMac = AppInfo(appID: 100, name: "Fixture", depots: [DepotInfo(id: 101, osList: "windows", manifestGID: 101)], launches: [])
        XCTAssertThrowsError(try SteamPlanBuilder.selectedDepots(noMac, ownedApps: [100], platform: .macOS))
    }
    func testDepotsWithoutPublicContentAreSkipped() throws {
        // DEMON'S TILT lists a beta-only and an empty Mac depot beside the real one.
        let app = AppInfo(appID: 100, name: "Fixture", depots: [
            DepotInfo(id: 101, osList: "windows", manifestGID: 101), DepotInfo(id: 102, osList: "macos", manifestGID: 102),
            DepotInfo(id: 103, osList: "macos"), DepotInfo(id: 104, osList: "macos", manifestGID: 0),
        ], launches: [])
        XCTAssertEqual(try SteamPlanBuilder.selectedDepots(app, ownedApps: [100], platform: .macOS).map(\.id), [102])
        let betaOnly = AppInfo(appID: 100, name: "Fixture", depots: [DepotInfo(id: 103, osList: "macos")], launches: [])
        XCTAssertThrowsError(try SteamPlanBuilder.selectedDepots(betaOnly, ownedApps: [100], platform: .macOS))
    }

    func testPOSIXArgumentsFollowShellQuoting() throws {
        XCTAssertEqual(try POSIXArguments.parse(#"-a 'single quoted' "double \"x\"" back\ slash"#), ["-a", "single quoted", #"double "x""#, "back slash"])
        XCTAssertThrowsError(try POSIXArguments.parse("\"unterminated"))
        XCTAssertEqual(try POSIXArguments.parse("   "), [])
    }

    func testMacPreparationReplacesTheAPIKeepsOriginalsAndSignsOnlyTheBundle() async throws {
        let files = macFiles
        let chunks = self.chunks
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(files, depot: 102)], entitlements: .init(appIDs: [100], depotIDs: [102]))
        let signer = FixtureSigner(), saves = try temporaryDirectory()
        let installer = SteamInstaller(game: game, backend: MacBackend(content: content, chunks: chunks), emulatorSaves: saves, codeSigner: signer)
        let plan = try await installer.resolve(platform: .macOS), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let bottle = GameBottle(gameID: game.id, name: "playden-steam-100", ownershipToken: UUID())
        let staging = try await installer.postInstall(plan, at: directory, in: bottle)
        XCTAssertEqual(staging.version, 3)
        XCTAssertEqual(Set(staging.mutations.map(\.relativePath)), ["Game.app/Contents/Frameworks/libsteam_api.dylib",
            "Game.app/Contents/MacOS/Game", "Game.app/Contents/_CodeSignature/CodeResources"])
        let library = directory.appendingPathComponent("Game.app/Contents/Frameworks/libsteam_api.dylib")
        XCTAssertEqual(try Data(contentsOf: library), try Data(contentsOf: MacGBEAsset.bundled().library))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".playden-originals/Game.app/Contents/Frameworks/libsteam_api.dylib")), machO + Data("valve".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Game.app/Contents/Frameworks/steam_settings").path),
                       "Settings never go inside the signed bundle")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".playden-steam/steam_settings/steam_appid.txt"), encoding: .utf8), "100")
        let user = try String(contentsOf: directory.appendingPathComponent(".playden-steam/steam_settings/configs.user.ini"), encoding: .utf8)
        XCTAssertTrue(user.contains("local_save_path=" + saves.appendingPathComponent("100").path), "Emulator saves live outside the game folder")
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("Game.app/Contents/MacOS/Game").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
        let signed = await signer.signed
        XCTAssertEqual(signed, ["Game.app"])

        let spec = try await installer.validate(plan, at: directory, staging: staging)
        XCTAssertEqual(spec.environment["GseAppPath"], "@game/.playden-steam")
        XCTAssertEqual(spec.environment(expandingIn: directory)["GseAppPath"], directory.appendingPathComponent(".playden-steam").path)
        let verified = await signer.verified
        XCTAssertEqual(verified, ["Game.app"])
        let intact = try await installer.verifyOriginals(plan, at: directory, staging: staging)
        XCTAssertTrue(intact.isValid, "Verify files checks the kept originals, not the re-signed copies")
        let again = try await installer.postInstall(plan, at: directory, in: bottle)
        XCTAssertEqual(Set(again.mutations.map(\.relativePath)), Set(staging.mutations.map(\.relativePath)), "Preparing again reuses the kept originals")

        XCTAssertEqual(try installer.saveMapping(plan).unresolved, ["Reinstall this game to sync its saves with Steam Cloud."],
                       "Plans saved before Mac Cloud support have no Mac save locations")
        XCTAssertFalse(try installer.supportsCloudSaves(plan))
    }

    func testMacSigningRejectsManifestSealSymlinkBeforeInvokingSigner() async throws {
        let seal = "Game.app/Contents/_CodeSignature/CodeResources"
        let target = "Game.app/Contents/Resources/original-seal"
        let bytes = Data("original seal".utf8)
        let files = macFiles.filter { $0.path != seal } + [file(target, bytes),
            .init(path: seal, size: 0, flags: 512, linkTarget: "../Resources/original-seal", chunks: [])]
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(files, depot: 102)],
            entitlements: .init(appIDs: [100], depotIDs: [102]))
        let signer = FixtureSigner()
        let installer = SteamInstaller(game: game, backend: MacBackend(content: content, chunks: chunks),
            emulatorSaves: try temporaryDirectory(), codeSigner: signer)
        let plan = try await installer.resolve(platform: .macOS), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let bottle = GameBottle(gameID: game.id, name: "playden-steam-100", ownershipToken: UUID())
        do { _ = try await installer.postInstall(plan, at: directory, in: bottle); XCTFail("Signing followed a manifest seal link") }
        catch SteamError.prepare(let message) {
            let sealPath = try SteamPreparationPaths(root: directory).root.appendingPathComponent(seal).path
            XCTAssertEqual(message, "a preparation path is linked or has an unexpected file type: \(sealPath)")
        }
        let signed = await signer.signed
        XCTAssertEqual(signed, [])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(target)), bytes)
    }

    func testUnsignedMacBundlesAreNotSigned() async throws {
        let files = macFiles.filter { !$0.path.contains("_CodeSignature") }
        let chunks = self.chunks
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(files, depot: 102)], entitlements: .init(appIDs: [100], depotIDs: [102]))
        let signer = FixtureSigner()
        let installer = SteamInstaller(game: game, backend: MacBackend(content: content, chunks: chunks), emulatorSaves: try temporaryDirectory(), codeSigner: signer)
        let plan = try await installer.resolve(platform: .macOS), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        let bottle = GameBottle(gameID: game.id, name: "playden-steam-100", ownershipToken: UUID())
        let staging = try await installer.postInstall(plan, at: directory, in: bottle)
        XCTAssertEqual(staging.mutations.map(\.relativePath), ["Game.app/Contents/Frameworks/libsteam_api.dylib"], "Only the Steam API changes")
        _ = try await installer.validate(plan, at: directory, staging: staging)
        let signed = await signer.signed, verified = await signer.verified
        XCTAssertEqual(signed, []); XCTAssertEqual(verified, [])
    }

    func testMacPreparationRejectsWriteLinksThatLeaveTheGameFolder() async throws {
        let files = macFiles
        let chunks = self.chunks
        let content = ResolvedSteamContent(app: app(), manifests: [manifest(files, depot: 102)], entitlements: .init(appIDs: [100], depotIDs: [102]))
        let installer = SteamInstaller(game: game, backend: MacBackend(content: content, chunks: chunks), emulatorSaves: try temporaryDirectory(), codeSigner: FixtureSigner())
        let plan = try await installer.resolve(platform: .macOS), directory = try temporaryDirectory()
        try await installer.download(plan, to: directory) { _ in }
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent(".playden-steam").path, withDestinationPath: "/tmp")
        let bottle = GameBottle(gameID: game.id, name: "playden-steam-100", ownershipToken: UUID())
        do { _ = try await installer.postInstall(plan, at: directory, in: bottle); XCTFail("An escaping link was accepted") }
        catch {}
        try FileManager.default.removeItem(at: directory.appendingPathComponent(".playden-steam"))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("Game.app/Contents/Current").path, withDestinationPath: "MacOS")
        _ = try await installer.postInstall(plan, at: directory, in: bottle)
    }
}

private extension Data {
    var sha1: Data { Data(Insecure.SHA1.hash(data: self)) }
}

final class AdHocCodeSignerTests: XCTestCase {
    func testSignsABundleWhoseLibraryWasReplaced() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdHocSign-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Game.app"), contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": "Game", "CFBundleIdentifier": "com.example.signed", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let source = root.appendingPathComponent("main.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["clang", "-o", contents.appendingPathComponent("MacOS/Game").path, source.path]
        try compile.run(); compile.waitUntilExit()
        try XCTSkipUnless(compile.terminationStatus == 0, "A C compiler is needed for this fixture")
        try FileManager.default.copyItem(at: MacGBEAsset.bundled().library, to: contents.appendingPathComponent("Frameworks/libsteam_api.dylib"))
        let signer = AdHocCodeSigner()
        try await signer.sign(bundle)
        try await signer.verify(bundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: contents.appendingPathComponent("_CodeSignature/CodeResources").path))
    }
}
