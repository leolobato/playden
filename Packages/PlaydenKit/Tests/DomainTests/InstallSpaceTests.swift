import XCTest
@testable import Domain

final class InstallSpaceTests: XCTestCase {
    func testChecksActualDestinationAncestorAndRejectsLowSpaceAndOverflow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("runtime/bottle")
        try InstallSpace.require(100, at: missing) { volume in
            XCTAssertEqual(volume.path, root.path); return 100
        }
        XCTAssertThrowsError(try InstallSpace.require(101, at: missing) { _ in 100 })
        XCTAssertThrowsError(try InstallSpace.add(.max, 1))
        let file = root.appendingPathComponent("original")
        try Data(repeating: 1, count: 17).write(to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: file)
        XCTAssertEqual(try InstallSpace.copyBytes(in: root), 17)
    }
}
