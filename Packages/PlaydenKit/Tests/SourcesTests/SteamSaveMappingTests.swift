import XCTest
import Domain
import SteamCore
@testable import Sources

final class SteamSaveMappingTests: XCTestCase {
    func testAPIOnlyCloudGamesUseExactGBERemoteDirectory() {
        let mapping = SteamSaveMapping.build(UFS(quota: 262144, maxNumFiles: 4), appID: 310790)
        XCTAssertEqual(mapping.coverage, .metadata)
        XCTAssertTrue(mapping.unresolved.isEmpty)
        XCTAssertEqual(mapping.rules.last, .init(root: .bottle,
            directory: "drive_c/Program Files (x86)/Steam/userdata/0/310790/remote", cloudPrefix: ""))
        XCTAssertFalse(mapping.permitsRemovingUnmappedFiles)
        XCTAssertEqual(SteamSaveMapping.build(UFS(), appID: 123).coverage, .unknown)
    }

    func testAutoCloudAndAPISavesCoexistAndSteamUserDataIsSupported() {
        let mapping = SteamSaveMapping.build(UFS(saveFilePatterns: [
            .init(root: .WinMyDocuments, path: "MGR/SaveData", pattern: "MGR.sav", recursive: 1),
            .init(root: .SteamUserData, path: "", pattern: "*")
        ]), appID: 235460)
        XCTAssertEqual(mapping.coverage, .metadata)
        XCTAssertTrue(mapping.rules.contains { $0.cloudPrefix == "" })
        XCTAssertTrue(mapping.rules.contains { $0.cloudPrefix == "%WinMyDocuments%MGR/SaveData" })
    }

    func testShortHikeUFSKeepsLocalAndCloudPathsDistinctFromGBEStorage() {
        let mapping = SteamSaveMapping.build(UFS(quota: 20_000_000, maxNumFiles: 3, saveFilePatterns: [
            .init(root: .WinAppDataLocalLow, path: "adamgryu/A Short Hike", pattern: "*.mountain")
        ]))
        XCTAssertEqual(mapping.coverage, .metadata)
        XCTAssertFalse(mapping.permitsRemovingUnmappedFiles, "UFS metadata is not gameplay/save-retention proof")
        XCTAssertTrue(mapping.unresolved.isEmpty)
        XCTAssertEqual(mapping.rules, [
            .init(root: .bottle, directory: "drive_c/Program Files (x86)/Steam/userdata/0"),
            .init(root: .bottle, directory: "drive_c/users/crossover/AppData/LocalLow/adamgryu/A Short Hike",
                  pattern: "*.mountain", recursive: false, cloudPrefix: "%WinAppDataLocalLow%adamgryu/A Short Hike")
        ])
    }
    func testRootOverrideAndAddedLocalPathPreserveOriginalUploadPrefix() {
        let mapping = SteamSaveMapping.build(UFS(saveFilePatterns: [
            .init(root: .WinAppDataRoaming, path: "MyGame/saves", pattern: "*.sav", recursive: 1,
                  uploadRoot: .GameInstall, uploadPath: "saves")
        ]))
        XCTAssertEqual(mapping.rules.last?.directory, "drive_c/users/crossover/AppData/Roaming/MyGame/saves")
        XCTAssertEqual(mapping.rules.last?.cloudPrefix, "%GameInstall%saves")
        XCTAssertEqual(mapping.rules.last?.recursive, true)
    }
    func testReplacedAccountPathsResolveDifferentLocalAndRemoteIdentities() throws {
        let template = SteamSaveMapping.build(UFS(quota: 48_000_000, maxNumFiles: 6, saveFilePatterns: [
            .init(root: .WinAppDataLocalLow, path: "SadCatStudios/Replaced/saves/{64BitSteamID}", pattern: "player*.*")
        ]), appID: 1663850)
        XCTAssertEqual(template.coverage, .metadata)
        XCTAssertTrue(template.unresolved.isEmpty)
        XCTAssertTrue(template.requiresSteamAccountResolution)
        let local: UInt64 = 76_561_198_012_345_678, remote = local + 1
        let resolved = try SteamCloudReader.resolveAccountPaths(template, localSteamID: local, remoteSteamID: remote)
        let rule = try XCTUnwrap(resolved.rules.first { $0.pattern == "player*.*" })
        XCTAssertEqual(rule.directory, "drive_c/users/crossover/AppData/LocalLow/SadCatStudios/Replaced/saves/\(local)")
        XCTAssertEqual(rule.cloudPrefix, "%WinAppDataLocalLow%SadCatStudios/Replaced/saves/\(remote)")
        XCTAssertEqual(resolved.boundAccountKey, SteamCloudReader.accountKey(remote))
        XCTAssertEqual(resolved.declaration, template)
        XCTAssertFalse(resolved.requiresSteamAccountResolution)
        XCTAssertFalse(resolved.permitsRemovingUnmappedFiles)
        XCTAssertTrue(resolved.rules.contains { $0.cloudPrefix == nil && $0.directory.hasSuffix("Replaced/saves") })
        XCTAssertEqual(try JSONDecoder().decode(SaveMapping.self, from: JSONEncoder().encode(resolved)), resolved)
    }

    func testAccountTokensValidateBeforeAndAfterExpansion() throws {
        let identity: UInt64 = 76_561_198_012_345_678
        let template = SteamSaveMapping.build(UFS(saveFilePatterns: [
            .init(root: .WinMyDocuments, path: "Game/{Steam3AccountID}", pattern: "*.sav")
        ]))
        let resolved = try SteamCloudReader.resolveAccountPaths(template, localSteamID: identity, remoteSteamID: identity + 1)
        XCTAssertTrue(resolved.rules.contains { $0.cloudPrefix?.hasSuffix("Game/\(UInt32(truncatingIfNeeded: identity + 1))") == true })
        XCTAssertThrowsError(try SteamCloudReader.resolveAccountPaths(template, localSteamID: 0, remoteSteamID: identity))
        XCTAssertThrowsError(try SteamCloudReader.resolveAccountPaths(template, localSteamID: identity, remoteSteamID: UInt64.max))
        for path in ["Game/{64BitSteamID}/../outside", "Game/{64BitSteamID}/{Unknown}"] {
            let invalid = SteamSaveMapping.build(UFS(saveFilePatterns: [.init(root: .WinMyDocuments, path: path, pattern: "*")]))
            XCTAssertEqual(invalid.coverage, .unknown)
        }
    }

    func testUnknownRootsTraversalAndUnverifiedIdentityNeverBecomeOwnedMappings() {
        for item in [
            SaveFilePattern(root: .LinuxHome, path: "Windows", pattern: "*"),
            .init(root: .GameInstall, path: "../outside", pattern: "*"),
            .init(root: .WinAppDataLocal, path: "C:\\outside", pattern: "*"),
            .init(root: .WinAppDataLocalLow, path: "Game/{UnknownAccount}", pattern: "*"),
            .init(root: .SteamUserData, path: "Game", pattern: "*"),
            .init(root: .GameInstall, path: "saves", pattern: "../*"),
            .init(root: .GameInstall, path: "saves", pattern: "*", uploadPath: "../remote")
        ] {
            let mapping = SteamSaveMapping.build(UFS(saveFilePatterns: [item]))
            XCTAssertEqual(mapping.coverage, .unknown)
            XCTAssertFalse(mapping.unresolved.isEmpty)
            XCTAssertTrue(mapping.rules.allSatisfy { $0.cloudPrefix == nil })
            XCTAssertFalse(mapping.permitsRemovingUnmappedFiles)
        }
        let noMetadata = SteamSaveMapping.build(UFS())
        XCTAssertEqual(noMetadata.coverage, .unknown)
        XCTAssertEqual(noMetadata.rules.count, 1, "Keep known GBE data without claiming it covers an unknown game")
    }
}
