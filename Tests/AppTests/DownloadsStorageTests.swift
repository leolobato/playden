import XCTest
import Domain
import Installs
@testable import BigScreen

final class DownloadsStorageTests: XCTestCase {
    @MainActor func testVolumeChangeRejectsOldReadAndFailureClearsPreviousFigures() async throws {
        let reader = HeldStorageReader(), model = LibraryModel(preview: false, gamesStorageReader: reader)
        let first = selection("first"), second = selection("second")
        model.gamesVolume = first
        let read = Task { await model.refreshGamesStorage() }
        for _ in 0..<200 where !(await reader.started) { try await Task.sleep(for: .milliseconds(5)) }
        let started = await reader.started; XCTAssertTrue(started)
        model.gamesVolume = second
        await reader.release(); await read.value
        XCTAssertNil(model.gamesStorage)
        await model.refreshGamesStorage()
        XCTAssertEqual(model.downloadStorage?.volumeID, "second")
        await reader.fail()
        await model.refreshGamesStorage()
        XCTAssertNil(model.gamesStorage); XCTAssertNil(model.downloadStorage)
        XCTAssertEqual(model.gamesStorageError, "Reconnect your games drive.")
    }
    @MainActor func testReservationsRefreshFromQueueWithoutWaitingForFilesystemScan() async {
        let reader = HeldStorageReader(); await reader.release()
        let model = LibraryModel(preview: false, gamesStorageReader: reader)
        model.gamesVolume = selection("first"); await model.refreshGamesStorage()
        var job = JobRecord(gameID: .init(source: "fake", value: "game"))
        job.volume = model.gamesVolume
        job.plan = .init(game: .init(id: job.gameID, title: "Test"), manifestIDs: [:],
            estimate: .init(downloadBytes: 100, installedBytes: 200, requiredBytes: 300),
            launchSpec: .init(executableRelativePath: "game.exe"), sourcePayload: Data())
        model.installJobs = [job]
        XCTAssertEqual(model.downloadStorage?.reservedBytes, 300)
        model.installJobs[0].bytesCompleted = 100
        XCTAssertEqual(model.downloadStorage?.reservedBytes, 200)
        model.installJobs[0].state = .cancelled
        XCTAssertEqual(model.downloadStorage?.reservedBytes, 0)
    }
    private func selection(_ id: String) -> GamesVolumeSelection {
        .init(volumeID: id, rootBookmark: Data(), lastKnownRoot: URL(fileURLWithPath: "/" + id), relativeRoot: "games")
    }
}
private actor HeldStorageReader: GamesStorageReading {
    var started = false
    private var held = true, failing = false
    func release() { held = false }
    func fail() { failing = true }
    func snapshot(on selection: GamesVolumeSelection, installations: [InstallationRecord], jobs: [JobRecord]) async throws -> GamesStorageSnapshot {
        started = true
        while held { try await Task.sleep(for: .milliseconds(5)) }
        if failing { throw OperationFailure(stage: "Storage", reason: "Reconnect your games drive.", output: "Test drive disconnected") }
        return .init(volumeID: selection.volumeID, name: selection.volumeID, root: selection.lastKnownRoot,
            totalBytes: 1000, freeBytes: 500, gamesBytes: 100, reservedBytes: 0)
    }
}
