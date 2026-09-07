import XCTest
import Domain
import Installs

final class GamesVolumeStoreTests: XCTestCase {
    func testSelectionPersistsIdentityAndBookmarkAndRejectsAnotherVolume() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("BigScreen-volume-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = GamesVolumeStore(home: home)
        let choices = try await store.availableVolumes()
        let local = try XCTUnwrap(choices.first(where: { $0.name == "This Mac" }))
        let selected = try await store.select(local)
        let restored = try JSONDecoder().decode(GamesVolumeSelection.self, from: JSONEncoder().encode(selected))
        let root = try await store.resolve(restored)
        XCTAssertEqual(root.resolvingSymlinksInPath(), local.gamesRoot.resolvingSymlinksInPath())
        XCTAssertFalse(selected.rootBookmark.isEmpty)
        var wrongVolume = restored; wrongVolume.volumeID = UUID().uuidString
        do { _ = try await store.resolve(wrongVolume); XCTFail("A mount path must never override volume identity") }
        catch { XCTAssertTrue(error is OperationFailure) }
    }
}
