import XCTest
import Darwin
import Domain
@testable import Installs

final class GamesStorageTests: XCTestCase {
    func testReservationUsesRemainingInstallBytesAcrossPausedAndFailedJobs() {
        let volume = selection(URL(fileURLWithPath: "/test"))
        func job(_ state: JobState, _ kind: JobKind = .install, completed: Int64 = 30) -> JobRecord {
            var job = JobRecord(gameID: .init(source: "fake", value: UUID().uuidString), kind: kind)
            job.state = state; job.volume = volume; job.bytesCompleted = completed
            job.plan = .init(game: .init(id: job.gameID, title: "Test"), manifestIDs: [:],
                estimate: .init(downloadBytes: 50, installedBytes: 80, requiredBytes: 100),
                launchSpec: .init(executableRelativePath: "game.exe"), sourcePayload: Data())
            return job
        }
        let running = job(.running)
        var elsewhere = job(.queued); elsewhere.volume?.volumeID = "another drive"
        let jobs = [running, job(.queued), job(.paused), job(.failed), job(.completed), job(.cancelled),
                    job(.running, .repair), job(.running, .uninstall), job(.queued, completed: 200), elsewhere]
        XCTAssertEqual(InstallReservations.bytes(jobs, on: volume.volumeID), 280)
        XCTAssertEqual(InstallReservations.bytes(jobs, on: volume.volumeID, excluding: running.id), 210)
        var huge = running
        huge.plan = .init(game: running.plan!.game, manifestIDs: [:], estimate: .init(downloadBytes: 0, installedBytes: 0, requiredBytes: .max),
            launchSpec: .init(executableRelativePath: "game.exe"), sourcePayload: Data())
        huge.bytesCompleted = .min
        XCTAssertEqual(InstallReservations.bytes([huge, running], on: volume.volumeID), .max)
    }
    func testCapacityPartitionsDoNotDoubleCountReservationsOrBecomeNegative() {
        let value = GamesStorageSnapshot(volumeID: "test", name: "Test", root: URL(fileURLWithPath: "/"),
            totalBytes: 1000, freeBytes: 400, gamesBytes: 200, reservedBytes: 150)
        XCTAssertEqual(value.gamesBytes, 200); XCTAssertEqual(value.otherBytes, 400)
        XCTAssertEqual(value.availableBytes, 250); XCTAssertEqual(value.shortageBytes, 0)
        XCTAssertEqual(value.gamesBytes! + value.otherBytes + value.availableBytes + value.reservedBytes, value.totalBytes)
        let over = GamesStorageSnapshot(volumeID: "test", name: "Test", root: value.root,
            totalBytes: 1000, freeBytes: 400, gamesBytes: 2000, reservedBytes: 500)
        XCTAssertEqual(over.gamesBytes, 600); XCTAssertEqual(over.otherBytes, 0)
        XCTAssertEqual(over.availableBytes, 0); XCTAssertEqual(over.shortageBytes, 100)
    }
    func testOwnedFilesAndPartialDownloadsExcludeLinksOtherVolumesAndDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BigScreen-storage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let volumes = StorageTestVolumes(root: root), selected = selection(root)
        let storage = InstallStorage(volumes: volumes)
        let first = GameID(source: "fake", value: "one"), owner = UUID()
        let location = try await storage.prepare(gameID: first, owner: owner, on: selected)
        let directory = try await storage.directory(location, gameID: first, owner: owner)
        let file = directory.appendingPathComponent("game.bin")
        try Data(repeating: 0x35, count: 80_001).write(to: file)
        try FileManager.default.linkItem(at: file, to: directory.appendingPathComponent("same-blocks.bin"))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 0x74, count: 900_000).write(to: outside.appendingPathComponent("private.bin"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("external"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("cycle"), withDestinationURL: directory)
        var install = InstallationRecord(game: .init(id: first, title: "Test"), location: location, bottleID: "test",
            ownershipToken: owner, manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "game.bin"), installedBytes: 9_000_000)
        var duplicate = JobRecord(gameID: first, kind: .repair); duplicate.location = location; duplicate.ownershipToken = owner
        var partial = JobRecord(gameID: .init(source: "fake", value: "partial"))
        partial.location = try await storage.prepare(gameID: partial.gameID, owner: partial.ownershipToken, on: selected)
        let partialDirectory = try await storage.directory(partial.location!, gameID: partial.gameID, owner: partial.ownershipToken)
        let part = partialDirectory.appendingPathComponent("chunk.part")
        try Data(repeating: 0x49, count: 12_001).write(to: part)
        let reader = GamesStorageReader(volumes: volumes, storage: storage)
        let snapshot = try await reader.snapshot(on: selected, installations: [install], jobs: [duplicate, partial])
        var info = stat(), partInfo = stat(); XCTAssertEqual(lstat(file.path, &info), 0); XCTAssertEqual(lstat(part.path, &partInfo), 0)
        XCTAssertEqual(snapshot.gamesBytes, (info.st_blocks + partInfo.st_blocks) * 512)
        install.location.volumeID = "other"
        let filtered = try await reader.snapshot(on: selected, installations: [install], jobs: [partial])
        XCTAssertEqual(filtered.gamesBytes, partInfo.st_blocks * 512)
        install.location = location; install.ownershipToken = UUID()
        let invalid = try await reader.snapshot(on: selected, installations: [install], jobs: [])
        XCTAssertNil(invalid.gamesBytes, "An unverified folder is not counted as zero or scanned")
        await volumes.disconnect()
        do { _ = try await reader.snapshot(on: selected, installations: [], jobs: []); XCTFail("Disconnected drive must not report stale capacity") }
        catch { XCTAssertTrue(error is OperationFailure) }
    }
    private func selection(_ root: URL) -> GamesVolumeSelection {
        .init(volumeID: "test-volume", rootBookmark: Data(), lastKnownRoot: root, relativeRoot: "games")
    }
}
private actor StorageTestVolumes: VolumeManaging {
    let root: URL
    var connected = true
    init(root: URL) { self.root = root }
    func disconnect() { connected = false }
    func availableVolumes() async throws -> [GamesVolume] { [] }
    func select(_ volume: GamesVolume) async throws -> GamesVolumeSelection { throw CancellationError() }
    func resolve(_ selection: GamesVolumeSelection) async throws -> URL {
        guard connected, selection.volumeID == "test-volume" else {
            throw OperationFailure(stage: "Games volume", reason: "Reconnect your games drive.", output: "Test volume disconnected")
        }
        return root
    }
}
