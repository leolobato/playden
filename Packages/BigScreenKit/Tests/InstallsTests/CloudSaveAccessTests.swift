import XCTest
import Foundation
import Domain
import Catalog
import Runner
@testable import Installs

private struct AccessStorage: InstallStorageManaging {
    let expected: InstallationRecord
    var refused = false
    var onAccess: (@Sendable () throws -> Void)?
    func freeBytes(on volume: GamesVolumeSelection) async throws -> Int64 { throw SourceFailure.unavailable }
    func prepare(gameID: GameID, owner: UUID, on volume: GamesVolumeSelection) async throws -> GameLocation { throw SourceFailure.unavailable }
    func directory(_ location: GameLocation, gameID: GameID, owner: UUID) async throws -> URL {
        guard !refused, location == expected.location, gameID == expected.gameID, owner == expected.ownershipToken else { throw SourceFailure.unavailable }
        try onAccess?()
        return URL(fileURLWithPath: "/fixture/owned-game")
    }
    func remove(_ location: GameLocation, gameID: GameID, owner: UUID) async throws { throw SourceFailure.unavailable }
}
private struct AccessBottles: GameBottleManaging {
    let expected: InstallationRecord
    var refused = false
    func prepare(_ bottle: GameBottle) async throws { throw SourceFailure.unavailable }
    func isReady(_ bottle: GameBottle) async throws -> Bool { false }
    func remove(_ bottle: GameBottle) async throws { throw SourceFailure.unavailable }
    func ownedDirectory(_ bottle: GameBottle) async throws -> URL {
        guard !refused, bottle.gameID == expected.gameID, bottle.name == expected.bottleID,
              bottle.ownershipToken == expected.ownershipToken, bottle.templateVersion == expected.templateVersion else { throw SourceFailure.unavailable }
        return URL(fileURLWithPath: "/fixture/owned-bottle")
    }
}
private struct AccessInspector: RuntimeInspecting {
    var observation = RuntimeObservation(processes: [])
    var identities: [Int32: ProcessIdentity] = [:]
    var refused = false
    func inspect(bottle: URL) throws -> RuntimeObservation {
        guard !refused, bottle.path == "/fixture/owned-bottle" else { throw SourceFailure.unavailable }
        return observation
    }
    func identity(of pid: Int32) -> ProcessIdentity? { identities[pid] }
}

final class CloudSaveAccessTests: XCTestCase {
    private let gameID = GameID(source: "steam", value: "1055540")
    private func installed(_ store: CatalogStore) throws -> InstallationRecord {
        let value = InstallationRecord(game: .init(id: gameID, title: "A Short Hike"),
            location: .init(volumeID: "fixture", lastKnownRoot: URL(fileURLWithPath: "/fixture"), relativePath: "game"),
            bottleID: "gn-steam-1055540", manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "ShortHike.exe"), installedBytes: 1)
        try store.saveInstallation(value); return value
    }
    private func process(_ pid: Int32, kind: RuntimeProcessKind = .game, birth: UInt64 = 1) -> RuntimeProcess {
        .init(identity: .init(pid: pid, startSeconds: birth, startMicroseconds: 0), kind: kind, executable: "fixture")
    }
    private func exited(_ installed: InstallationRecord, _ store: CatalogStore, ended: Bool = true) throws -> PlaySessionRecord {
        let bottle = GameBottle(gameID: gameID, name: installed.bottleID, ownershipToken: installed.ownershipToken, templateVersion: installed.templateVersion)
        var session = PlaySessionRecord(gameID: gameID, bottleID: installed.bottleID, startedAt: Date(timeIntervalSince1970: 1))
        session.runtime = .init(run: .init(bottle: bottle, launcher: process(123, kind: .wrapper).identity), phase: .exited,
            processes: [process(124), process(125, kind: .server)], hadWindow: true, exitCode: 1)
        if ended { session.endedAt = session.startedAt; session.outcome = .crash }
        try store.saveSession(session); return session
    }
    private func access(_ store: CatalogStore, _ installed: InstallationRecord, inspector: AccessInspector = .init()) -> CloudSaveAccess {
        .init(catalog: store, storage: AccessStorage(expected: installed), bottles: AccessBottles(expected: installed), inspector: inspector)
    }
    private func denied(_ access: CloudSaveAccess, _ installed: InstallationRecord, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await access.roots(for: installed); XCTFail("Unexpected save access", file: file, line: line) } catch { }
    }

    func testRequiresCurrentInstallationAndClaimAndReturnsBothOwnedRoots() async throws {
        let store = try CatalogStore(), installed = try installed(store), access = access(store, installed)
        await denied(access, installed)
        _ = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: .init())
        var stale = installed; stale.ownershipToken = UUID()
        await denied(access, stale)
        let roots = try await access.roots(for: installed)
        XCTAssertEqual(roots[.game]?.path, "/fixture/owned-game"); XCTAssertEqual(roots[.bottle]?.path, "/fixture/owned-bottle")
    }

    func testRefusesOwnershipAndInspectionFailuresWithoutPreparingBottle() async throws {
        let store = try CatalogStore(), installed = try installed(store)
        _ = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: .init())
        for failure in 0..<3 {
            let access = CloudSaveAccess(catalog: store, storage: AccessStorage(expected: installed, refused: failure == 0),
                bottles: AccessBottles(expected: installed, refused: failure == 1), inspector: AccessInspector(refused: failure == 2))
            await denied(access, installed)
        }
    }

    func testGameAndLauncherWritersBlockAccessButIdleWineServicesDoNot() async throws {
        let store = try CatalogStore(), installed = try installed(store)
        _ = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: .init())
        for kind in [RuntimeProcessKind.game, .wrapper] {
            await denied(access(store, installed, inspector: .init(observation: .init(processes: [process(44, kind: kind)]))), installed)
        }
        let inspector = AccessInspector(observation: .init(processes: [process(45, kind: .server), process(46, kind: .service)], unreadablePIDs: [999]))
        _ = try await access(store, installed, inspector: inspector).roots(for: installed)
    }

    func testMissingWriterRequiresBirthIdentityCheckAndUnrelatedPidReuseIsSafe() async throws {
        let store = try CatalogStore(), installed = try installed(store)
        let prior = try exited(installed, store)
        let pending = PlaySessionRecord(gameID: gameID, bottleID: installed.bottleID)
        try store.saveSession(pending)
        XCTAssertEqual(try store.latestRuntimeSession(for: gameID)?.id, prior.id)
        _ = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: .init(), preparingSessionID: pending.id)
        await denied(access(store, installed, inspector: .init(identities: [124: process(124).identity])), installed)
        await denied(access(store, installed, inspector: .init(observation: .init(processes: [], unreadablePIDs: [123]))), installed)
        let reused = AccessInspector(observation: .init(processes: [], unreadablePIDs: [123]), identities: [123: process(123, birth: 2).identity])
        _ = try await access(store, installed, inspector: reused).roots(for: installed)
    }

    func testExitedSessionIsAcceptedOnlyForItsOwnReservation() async throws {
        let store = try CatalogStore(), installed = try installed(store)
        let session = try exited(installed, store, ended: false)
        XCTAssertThrowsError(try store.beginCloudSync(installation: installed, accountKey: "a", mapping: .init()))
        _ = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: .init(), preparingSessionID: session.id)
        _ = try await access(store, installed).roots(for: installed)
    }

    func testClaimChangeDuringFolderResolutionRejectsStaleWorker() async throws {
        let store = try CatalogStore(), installed = try installed(store)
        let operation = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: .init())
        let storage = AccessStorage(expected: installed, onAccess: { _ = try store.pauseCloudSync(operation, phase: .pending) })
        let access = CloudSaveAccess(catalog: store, storage: storage, bottles: AccessBottles(expected: installed), inspector: AccessInspector())
        await denied(access, installed)
    }
}
