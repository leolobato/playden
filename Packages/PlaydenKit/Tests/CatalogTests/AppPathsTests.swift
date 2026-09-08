import XCTest
import Domain

final class AppPathsTests: XCTestCase {
    func testFreshProfileAndExistingLibraryUseOneConsistentRoot() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support")
        let current = support.appendingPathComponent("Playden", isDirectory: true)
        let legacy = support.appendingPathComponent("Big Screen", isDirectory: true)
        XCTAssertEqual(AppPaths.supportRoot(home: home), current)
        // The staging script may create Playden/Run before the app opens the old library.
        try FileManager.default.createDirectory(at: current.appendingPathComponent("Run"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let catalog = legacy.appendingPathComponent("catalog.sqlite")
        let bytes = Data("existing profile".utf8)
        try bytes.write(to: catalog)
        XCTAssertEqual(AppPaths.supportRoot(home: home), legacy)
        XCTAssertEqual(try Data(contentsOf: catalog), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.appendingPathComponent("catalog.sqlite").path))
    }
}
