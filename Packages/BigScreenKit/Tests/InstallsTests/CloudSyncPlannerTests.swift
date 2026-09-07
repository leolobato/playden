import XCTest
import Domain
@testable import Installs

final class CloudSyncPlannerTests: XCTestCase {
    let id = GameID(source: "steam", value: "1055540")
    let installation = UUID()
    let mapping = SaveMapping(rules: [
        .init(root: .bottle, directory: "drive_c/users/crossover/AppData/LocalLow/adamgryu/A Short Hike", pattern: "*.mountain", recursive: false,
              cloudPrefix: "%WinAppDataLocalLow%adamgryu/A Short Hike")
    ], coverage: .metadata)
    var location: CloudSavePath { .init(root: .bottle, path: "drive_c/users/crossover/AppData/LocalLow/adamgryu/A Short Hike/GameSaveNew.mountain") }
    var saveName: String { "%WinAppDataLocalLow%adamgryu/A Short Hike/GameSaveNew.mountain" }
    func local(_ hash: UInt8, time: TimeInterval = 100) -> CloudLocalFile {
        .init(location: location, sha1: Data(repeating: hash, count: 20), bytes: Int64(hash), modifiedAt: Date(timeIntervalSince1970: time))
    }
    func remote(_ hash: UInt8, state: CloudFile.State = .present, time: TimeInterval = 100) -> CloudFile {
        .init(name: saveName, sha1: Data(repeating: hash, count: 20), bytes: Int64(hash), modifiedAt: Date(timeIntervalSince1970: time), state: state)
    }
    func baseline(_ hash: UInt8, installationID: UUID? = nil, account: String = "a") -> CloudSyncBaseline {
        .init(gameID: id, installationID: installationID ?? installation, accountKey: account, revision: 1,
              mapping: mapping, files: [remote(hash)])
    }
    func plan(_ local: [CloudLocalFile], _ remote: [CloudFile], baseline: CloudSyncBaseline? = nil,
              account: String = "a", attached: String? = "a") throws -> CloudSyncPlan {
        try CloudSyncPlanner.plan(installationID: installation, mapping: mapping, localFiles: local,
            remote: .init(gameID: id, accountKey: account, revision: 2, files: remote), baseline: baseline,
            attachedAccountKey: attached)
    }
    func testThreeWayComparisonNeverUsesTimestampAsConflictWinner() throws {
        let base = baseline(1)
        XCTAssertEqual(try plan([local(1, time: 1000)], [remote(1, time: 2000)], baseline: base).decisions.first?.action, .unchanged)
        XCTAssertEqual(try plan([local(2, time: 1)], [remote(1, time: 2000)], baseline: base).decisions.first?.action, .upload)
        XCTAssertEqual(try plan([local(1, time: 2000)], [remote(2, time: 1)], baseline: base).decisions.first?.action, .download)
        let conflict = try plan([local(2, time: 2000)], [remote(3, time: 1)], baseline: base)
        XCTAssertTrue(conflict.hasConflicts); XCTAssertFalse(conflict.canApplyAutomatically)
        XCTAssertEqual(try plan([local(2)], [remote(2)], baseline: base).decisions.first?.action, .unchanged)
    }
    func testDeletionsRequireAValidBaselineAndDoNotWinAgainstEdits() throws {
        let base = baseline(1)
        XCTAssertEqual(try plan([], [remote(1)], baseline: base).decisions.first?.action, .deleteRemote)
        XCTAssertEqual(try plan([local(1)], [], baseline: base).decisions.first?.action, .deleteLocal)
        XCTAssertEqual(try plan([local(1)], [remote(1, state: .deleted)], baseline: base).decisions.first?.action, .deleteLocal)
        XCTAssertEqual(try plan([], [remote(2)], baseline: base).decisions.first?.action, .conflict)
        XCTAssertEqual(try plan([local(2)], [], baseline: base).decisions.first?.action, .conflict)
        XCTAssertTrue(try plan([], [], baseline: base).isUpToDate)
    }
    func testFirstSyncAndReinstallPullRemoteInsteadOfDeletingIt() throws {
        XCTAssertEqual(try plan([], [remote(1)]).decisions.first?.action, .download)
        XCTAssertEqual(try plan([local(2)], [remote(1)]).decisions.first?.action, .conflict)
        XCTAssertEqual(try plan([local(1)], [remote(1, state: .deleted)]).decisions.first?.action, .conflict)
        let oldInstall = baseline(1, installationID: UUID())
        let reinstall = try plan([], [remote(1)], baseline: oldInstall)
        XCTAssertEqual(reinstall.decisions.first?.action, .download)
        XCTAssertTrue(reinstall.canApplyAutomatically)
    }
    func testAccountAttachmentIsRequiredEvenIfCloudIsEmptyOrAlreadyMatches() throws {
        for remote in [[], [self.remote(1)]] {
            let first = try plan([local(1)], remote, attached: nil)
            XCTAssertTrue(first.requiresAccountConfirmation); XCTAssertFalse(first.canApplyAutomatically)
            let switched = try plan([local(1)], remote, account: "b", attached: "a")
            XCTAssertTrue(switched.requiresAccountConfirmation)
        }
        XCTAssertTrue(try plan([], [remote(1)], attached: nil).canApplyAutomatically)
        XCTAssertThrowsError(try plan([local(1)], [remote(1)], baseline: baseline(1), account: "b", attached: "b"))
    }
    func testUnknownAndForgottenRemoteFilesPreventAutomaticMutation() throws {
        let unknown = CloudFile(name: "%WinAppDataLocal%Unmapped/save.dat", sha1: Data(repeating: 1, count: 20), bytes: 1, modifiedAt: .now)
        let unsupported = try plan([], [unknown])
        XCTAssertTrue(unsupported.hasUnavailableFiles); XCTAssertFalse(unsupported.canApplyAutomatically)
        let forgotten = try plan([local(1)], [remote(1, state: .forgotten)], baseline: baseline(1))
        XCTAssertEqual(forgotten.decisions.first?.action, .unavailable)
    }
    func testUnmappedLocalBackupsAreExcludedAndRemoteAliasesCannotTargetSameFile() throws {
        let backup = CloudLocalFile(location: .init(root: location.root, path: location.path + "_backup"),
            sha1: Data(repeating: 1, count: 20), bytes: 1, modifiedAt: .now)
        XCTAssertTrue(try plan([backup], []).decisions.isEmpty)
        let alias = CloudFile(name: saveName.replacingOccurrences(of: "%adamgryu", with: "%/adamgryu"),
            sha1: remote(1).sha1, bytes: 1, modifiedAt: .now)
        XCTAssertThrowsError(try plan([], [remote(1), alias]))
        let update = try plan([local(2)], [alias], baseline: baseline(1))
        XCTAssertEqual(update.decisions.first?.name, alias.name, "An upload must preserve the server's existing spelling")
    }
    func testExistingLocalFilenameCaseIsPreservedForRemoteReplacement() throws {
        let changed = CloudFile(name: saveName.lowercased(), sha1: remote(2).sha1, bytes: 2, modifiedAt: .now)
        let result = try plan([local(1)], [changed], baseline: baseline(1))
        XCTAssertEqual(result.decisions.first?.action, .download)
        XCTAssertEqual(result.decisions.first?.location, location)
        XCTAssertEqual(result.decisions.first?.name, changed.name)
    }
    func testRegressedRevisionAndInvalidFingerprintsAreRejected() throws {
        let base = CloudSyncBaseline(gameID: id, installationID: installation, accountKey: "a", revision: 9,
            mapping: mapping, files: [remote(1)])
        XCTAssertThrowsError(try plan([], [remote(1)], baseline: base))
        let invalid = CloudLocalFile(location: location, sha1: Data(), bytes: 0, modifiedAt: .now)
        XCTAssertThrowsError(try plan([invalid], []))
    }
    func testRootOverridesPatternsAndNestedDirectoriesRoundtrip() throws {
        let paths = try CloudSavePaths(mapping: mapping)
        XCTAssertEqual(try paths.localPath(for: saveName), location)
        XCTAssertEqual(try paths.localPath(for: saveName.replacingOccurrences(of: "%adamgryu", with: "%/adamgryu")), location)
        XCTAssertEqual(try paths.remoteName(for: location), saveName)
        XCTAssertNil(try paths.localPath(for: saveName + "_backup"))
        XCTAssertNil(try paths.localPath(for: saveName.replacingOccurrences(of: "GameSaveNew", with: "nested/GameSaveNew")))
        let overridden = try CloudSavePaths(mapping: .init(rules: [
            .init(root: .bottle, directory: "drive_c/users/crossover/AppData/Roaming/Example", pattern: "*.sav", recursive: true,
                  cloudPrefix: "%GameInstall%saves")
        ], coverage: .metadata))
        let nested = try XCTUnwrap(overridden.localPath(for: "%GameInstall%/saves/profile/one.sav"))
        XCTAssertEqual(nested.path, "drive_c/users/crossover/AppData/Roaming/Example/profile/one.sav")
        XCTAssertEqual(try overridden.remoteName(for: nested), "%GameInstall%saves/profile/one.sav")
    }
    func testRemotePathsCannotTraverseOrSubstituteUnresolvedRoots() throws {
        let paths = try CloudSavePaths(mapping: mapping)
        for path in ["../outside", "/absolute", "%WinAppDataLocalLow%/../outside", "%WinAppDataLocalLow%//outside",
                     saveName + "/../other", saveName + "/./other", saveName + "\0", saveName + "\n", saveName + ":stream",
                     "%WinAppDataLocalLow%Game/{64BitSteamID}/save", "C:\\outside", "%unfinished"] {
            XCTAssertThrowsError(try paths.localPath(for: path), path)
        }
        XCTAssertThrowsError(try CloudSavePaths(mapping: .init(rules: mapping.rules, coverage: .unknown)))
        XCTAssertThrowsError(try CloudSavePaths(mapping: .init(rules: mapping.rules, coverage: .metadata, unresolved: ["Unknown"])))
        let ambiguous = SaveMapping(rules: mapping.rules + [.init(root: .game, directory: "elsewhere", pattern: "*.mountain", cloudPrefix: "%WinAppDataLocalLow%adamgryu/A Short Hike")], coverage: .metadata)
        XCTAssertThrowsError(try CloudSavePaths(mapping: ambiguous).localPath(for: saveName))
    }
}
