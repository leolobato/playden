import XCTest
@testable import Runner

final class WindowsExecutableIconTests: XCTestCase {
    func testReassemblesIconResourcesFrom32And64BitExecutables() throws {
        for wide in [false, true] {
            let data = fixture(wide: wide)
            let icon = try WindowsExecutableIcon.icon(in: data)
            XCTAssertEqual(Array(icon.prefix(6)), [0, 0, 1, 0, 1, 0])
            XCTAssertEqual(Array(icon[6..<14]), [32, 32, 0, 0, 1, 0, 32, 0])
            XCTAssertEqual(Array(icon[14..<22]), [4, 0, 0, 0, 22, 0, 0, 0])
            XCTAssertEqual(Array(icon.suffix(4)), [1, 2, 3, 4])
        }
    }
    func testNamedGroupIconsAreSupported() throws {
        var data = fixture(wide: false)
        data[512 + 0x38 + 12] = 1
        data[512 + 0x38 + 14] = 0
        data[512 + 0x38 + 19] = 128
        XCTAssertEqual(try WindowsExecutableIcon.icon(in: data).suffix(4), Data([1, 2, 3, 4]))
    }
    func testRejectsTruncatedAndOutOfBoundsResources() {
        let original = fixture(wide: true)
        for size in [0, 2, 63, 128, 300, 512, 700] {
            XCTAssertThrowsError(try WindowsExecutableIcon.icon(in: Data(original.prefix(size))))
        }
        for offset in [0x3c, 512 + 20, 512 + 0x84, 512 + 0x94] {
            var data = original
            data.replaceSubrange(offset..<(offset + 4), with: [255, 255, 255, 255])
            XCTAssertThrowsError(try WindowsExecutableIcon.icon(in: data))
        }
        var cyclic = original
        cyclic.replaceSubrange(532..<536, with: [0, 0, 0, 128])
        XCTAssertThrowsError(try WindowsExecutableIcon.icon(in: cyclic))
    }
    private func fixture(wide: Bool) -> Data {
        var data = Data(repeating: 0, count: 1536)
        func put(_ offset: Int, _ value: Int, _ size: Int = 4) {
            for index in 0..<size { data[offset + index] = UInt8((value >> (index * 8)) & 255) }
        }
        put(0, 0x5a4d, 2); put(0x3c, 128); put(128, 0x4550)
        put(134, 1, 2)
        let optional = 152, optionalSize = wide ? 240 : 224, directories = wide ? 112 : 96
        put(148, optionalSize, 2); put(optional, wide ? 0x20b : 0x10b, 2)
        put(optional + directories - 4, 16)
        put(optional + directories + 16, 0x1000); put(optional + directories + 20, 1024)
        let section = optional + optionalSize
        put(section + 12, 0x1000); put(section + 16, 1024); put(section + 20, 512)
        let root = 512
        put(root + 14, 2, 2)
        put(root + 16, 3); put(root + 20, 0x80000020)
        put(root + 24, 14); put(root + 28, 0x80000038)
        for (offset, id, target) in [(0x20, 7, 0x80000050), (0x38, 1, 0x80000068), (0x50, 1033, 0x80), (0x68, 1033, 0x90)] {
            put(root + offset + 14, 1, 2); put(root + offset + 16, id); put(root + offset + 20, target)
        }
        put(root + 0x80, 0x10a0); put(root + 0x84, 4)
        put(root + 0x90, 0x1200); put(root + 0x94, 20)
        data.replaceSubrange((root + 0xa0)..<(root + 0xa4), with: [1, 2, 3, 4])
        data.replaceSubrange(1024..<1044, with: [0, 0, 1, 0, 1, 0, 32, 32, 0, 0, 1, 0, 32, 0, 4, 0, 0, 0, 7, 0])
        return data
    }
}
