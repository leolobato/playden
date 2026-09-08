import XCTest
import Domain
import SteamCore
@testable import Sources

final class SteamSaveMappingTests: XCTestCase {
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
    func testUnknownRootsTraversalAndUnverifiedIdentityNeverBecomeOwnedMappings() {
        for item in [
            SaveFilePattern(root: .Root, path: "Windows", pattern: "*"),
            .init(root: .GameInstall, path: "../outside", pattern: "*"),
            .init(root: .WinAppDataLocal, path: "C:\\outside", pattern: "*"),
            .init(root: .WinAppDataLocalLow, path: "Game/{64BitSteamID}", pattern: "*"),
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
