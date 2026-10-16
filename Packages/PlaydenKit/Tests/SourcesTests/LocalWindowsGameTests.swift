import XCTest
import Domain
import Runner
@testable import Sources

final class LocalWindowsGameTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalWindowsGameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ path: String, bytes: Int = 4) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }
    private func source() -> LocalSource {
        LocalSource(store: LocalLibraryStore(file: root.appendingPathComponent("support/local-games.json")), suggestionRoots: [])
    }

    func testExecutablesListTheGameFirstAndHelpersLast() throws {
        try file("Blur/game/unins000.exe", bytes: 900)
        try file("Blur/game/Blur.exe", bytes: 100)
        try file("Blur/game/_Redist/dxsetup.exe", bytes: 2000)
        try file("Blur/game/_Redist/vcredist_x86.exe", bytes: 2000)
        try file("Blur/game/tools/Editor.exe", bytes: 5000)
        try file("Blur/game/UnityCrashHandler64.exe", bytes: 3000)
        let found = LocalWindowsGame.executables(in: root.appendingPathComponent("Blur/game"))
        XCTAssertEqual(found.map(\.relativePath).first, "Blur.exe", "The executable named like the game comes first")
        XCTAssertEqual(found.map(\.relativePath)[1], "tools/Editor.exe")
        XCTAssertEqual(Set(found.suffix(4).map(\.relativePath)), ["unins000.exe", "_Redist/dxsetup.exe", "_Redist/vcredist_x86.exe", "UnityCrashHandler64.exe"])
        XCTAssertTrue(found.suffix(4).allSatisfy(\.isLikelyHelper))
    }

    func testGenericFolderNamesUseTheParentAsTitle() {
        XCTAssertEqual(LocalWindowsGame.title(for: URL(fileURLWithPath: "/Games/Blur/game")), "Blur")
        XCTAssertEqual(LocalWindowsGame.title(for: URL(fileURLWithPath: "/Games/Hades")), "Hades")
    }

    func testAddedFolderPlaysInPlaceInItsOwnStableBottle() async throws {
        try file("Hades/x64/Hades.exe")
        let folder = root.appendingPathComponent("Hades")
        let local = source()
        let id = try await local.addWindowsGame(folder: folder, executable: "x64/Hades.exe")
        let games = try await local.ownedGames()
        XCTAssertEqual(games.map(\.title), ["Hades"]); XCTAssertEqual(games.first?.availablePlatforms, [.windows])
        XCTAssertTrue(local.installs(try XCTUnwrap(games.first)))
        let first = try await local.externalInstallations(for: games), second = try await local.externalInstallations(for: games)
        let install = try XCTUnwrap(first.first)
        var rescanned = try XCTUnwrap(second.first)
        rescanned.id = install.id // The catalog keeps the first record's id.
        XCTAssertEqual(rescanned, install, "Scans must not change the record, or the bottle loses its owner")
        XCTAssertTrue(install.isExternal); XCTAssertEqual(install.runtimeBinding, .crossOver)
        XCTAssertEqual(install.bottleID, CrossOverGameBottles.name(for: id))
        XCTAssertEqual(install.templateVersion, CrossOverRuntime.templateVersion)
        XCTAssertEqual(install.launchSpec.executableRelativePath, "x64/Hades.exe")
        XCTAssertEqual(install.launchSpec.workingDirectoryRelativePath, "x64")
        XCTAssertEqual(install.plan?.resolvedPlatform, .windows)
        let located = try await local.locate(install)
        XCTAssertEqual(LocalSource.realPath(located), LocalSource.realPath(folder), "Windows games resolve to their folder")
        let again = try await local.addWindowsGame(folder: folder, executable: "x64/Hades.exe")
        XCTAssertEqual(again, id)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Hades/x64/Hades.exe"))
        let missing = try await local.externalInstallations(for: games).first
        XCTAssertEqual(missing?.external?.availability, .missing)
    }

    func testAddingAFolderWithoutTheExecutableFails() async throws {
        try file("Empty/readme.txt")
        let local = source()
        do { _ = try await local.addWindowsGame(folder: root.appendingPathComponent("Empty"), executable: "Game.exe"); XCTFail("Expected failure") }
        catch let failure as OperationFailure { XCTAssertEqual(failure.stage, "Add game") }
        do { _ = try await local.addWindowsGame(folder: root.appendingPathComponent("Empty"), executable: "../readme.txt"); XCTFail("Expected failure") }
        catch let failure as OperationFailure { XCTAssertEqual(failure.stage, "Add game") }
    }

    func testRemovedFolderRestoresWithItsIdentityAndBottle() async throws {
        try file("Celeste/Celeste.exe")
        let local = source()
        let id = try await local.addWindowsGame(folder: root.appendingPathComponent("Celeste"), executable: "Celeste.exe")
        let token = try await local.externalInstallations(for: local.ownedGames()).first?.ownershipToken
        try await local.remove(id)
        let removed = try await local.removedGames()
        XCTAssertEqual(removed.map(\.found), [true])
        let restored = try await local.restore(id)
        XCTAssertEqual(restored, id)
        let restoredToken = try await local.externalInstallations(for: local.ownedGames()).first?.ownershipToken
        XCTAssertEqual(restoredToken, token)
        try await local.remove(id)
        let readded = try await local.addWindowsGame(folder: root.appendingPathComponent("Celeste"), executable: "Celeste.exe")
        XCTAssertEqual(readded, id, "Adding a removed folder again brings its history back")
    }

    func testRelocatedFolderKeepsItsIdentity() async throws {
        try file("Old/Game.exe")
        let local = source()
        let id = try await local.addWindowsGame(folder: root.appendingPathComponent("Old"), executable: "Game.exe")
        try FileManager.default.moveItem(at: root.appendingPathComponent("Old"), to: root.appendingPathComponent("Moved"))
        try file("Other/Game.exe")
        try await local.relocate(id, to: root.appendingPathComponent("Other"))
        let install = try await local.externalInstallations(for: local.ownedGames()).first
        XCTAssertEqual(install?.gameID, id)
        XCTAssertEqual(install?.external?.availability, .available)
        XCTAssertEqual(install.map { LocalSource.realPath($0.external!.lastKnownPath) }, LocalSource.realPath(root.appendingPathComponent("Other")))
    }

    func testCopyInstallerCopiesResumesAndValidates() async throws {
        try file("Blur/game/Blur.exe", bytes: 10_000)
        try file("Blur/game/levels/a/level.pak", bytes: 5 << 20)
        try file("Blur/game/english.txt", bytes: 10)
        let local = source()
        try await local.addWindowsGame(folder: root.appendingPathComponent("Blur/game"), executable: "Blur.exe")
        let owned = try await local.ownedGames()
        let game = try XCTUnwrap(owned.first)
        let installer = try local.installer(for: game)
        let plan = try await installer.resolve()
        XCTAssertEqual(plan.estimate.installedBytes, 10_000 + (5 << 20) + 10)
        XCTAssertEqual(plan.launchSpec.executableRelativePath, "Blur.exe")

        let target = root.appendingPathComponent("Playden/game")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // A half-copied file from an interrupted run is copied again.
        try FileManager.default.createDirectory(at: target.appendingPathComponent("levels/a"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3).write(to: target.appendingPathComponent("levels/a/level.pak"))
        let last = LockedValue<InstallProgress?>(nil)
        try await installer.download(plan, to: target) { last.set($0) }
        XCTAssertEqual(last.get()?.bytesCompleted, plan.estimate.installedBytes)
        let verified = try await installer.verifyOriginals(plan, at: target, staging: nil)
        XCTAssertTrue(verified.isValid)
        let spec = try await installer.validate(plan, at: target, staging: InstallStaging())
        XCTAssertEqual(spec.executableRelativePath, "Blur.exe")

        // The copy is checked against the plan, not the original, which the player may delete.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Blur"))
        let still = try await installer.verifyOriginals(plan, at: target, staging: nil)
        XCTAssertTrue(still.isValid)
        try FileManager.default.removeItem(at: target.appendingPathComponent("english.txt"))
        let damaged = try await installer.verifyOriginals(plan, at: target, staging: nil)
        XCTAssertEqual(damaged.invalidFiles, ["english.txt"])
    }

    func testMacAppsAreNeverInstalled() async throws {
        let local = source()
        var record = SourceGameRecord(id: GameID(source: SourceID.local, value: "x"), title: "Mac")
        record.platforms = [.macOS]
        XCTAssertFalse(local.installs(record))
        XCTAssertThrowsError(try local.installer(for: record))
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
