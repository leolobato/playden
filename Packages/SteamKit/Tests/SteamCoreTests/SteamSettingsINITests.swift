import XCTest
@testable import SteamCore

final class SteamSettingsINITests: XCTestCase {
    func testPreservesFormattingCommentsAndUpdatesEveryDuplicate() {
        let existing = "; per-game options\r\n[Main::Connectivity] ; keep\r\n offline = 0  ; local mode\r\ncustom=keep#value;here\r\n\r\n[main::connectivity]\r\noffline=0\r\n[other]\r\nvalue=unchanged"
        let generated = "[main::connectivity]\noffline=1\ndisable_networking=1\n"
        let result = SteamSettingsINI.merge(generated, into: existing)
        XCTAssertEqual(result, "; per-game options\r\n[Main::Connectivity] ; keep\r\n offline = 1  ; local mode\r\ncustom=keep#value;here\r\n\r\ndisable_networking=1\r\n[main::connectivity]\r\noffline=1\r\n[other]\r\nvalue=unchanged")
        XCTAssertEqual(SteamSettingsINI.merge(generated, into: result), result)
    }

    func testAuthoritativeSectionsAndRemovedKeysDoNotKeepStaleValues() {
        let existing = "[app::dlcs]\n; owned only\nunlock_all=1\n200=old\n300=not owned\n[app::cloud_save::win]\ndir1=old\n[user::general]\nticket=stale\nname=keep\n[custom]\nvalue=keep\n"
        let result = SteamSettingsINI.merge("[app::dlcs]\nunlock_all=0\n200=dlc200\n", into: existing,
            replacingSections: ["APP::DLCS", "app::cloud_save::win"], removingKeys: ["USER::GENERAL": ["TICKET"], "user::general": ["other"]])
        XCTAssertEqual(result, "[app::dlcs]\n; owned only\nunlock_all=0\n200=dlc200\n[app::cloud_save::win]\n[user::general]\nname=keep\n[custom]\nvalue=keep\n")
    }

    func testNewSectionsUnterminatedLinesAndDelimiterValues() {
        let generated = "global=new\n[user]\nname=new#name;with-delimiters\n[added]\nkey=value\n"
        let result = SteamSettingsINI.merge(generated, into: "global=old\n[user]\nname=old#name;value\ncustom=keep")
        XCTAssertEqual(result, "global=new\n[user]\nname=new#name;with-delimiters\ncustom=keep\n[added]\nkey=value\n")
        XCTAssertEqual(SteamSettingsINI.merge(generated, into: result), result)
    }

    func testBOMAndIdempotentWritesPreserveOriginalBytesAndTimestamp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.ini")
        let original = Data([0xef, 0xbb, 0xbf]) + Data("[user]\r\nname=old\r\ncustom=keep\r\n".utf8)
        try original.write(to: url)
        try SteamSettingsINI.write("[user]\nname=new\n", to: url)
        let expected = Data([0xef, 0xbb, 0xbf]) + Data("[user]\r\nname=new\r\ncustom=keep\r\n".utf8)
        XCTAssertEqual(try Data(contentsOf: url), expected)
        let timestamp = Date(timeIntervalSince1970: 123456)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        try SteamSettingsINI.write("[user]\nname=new\n", to: url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, timestamp)
        XCTAssertEqual(try Data(contentsOf: url), expected)
    }

    func testCreatesAbsentFileAndRejectsInvalidUTF8AndSymlinksWithoutChangingThem() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.ini"), generated = "[user]\nname=new\n"
        try SteamSettingsINI.write(generated, to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data(generated.utf8))
        let invalid = Data([0xff, 0xfe, 0x80])
        try invalid.write(to: url)
        XCTAssertThrowsError(try SteamSettingsINI.write(generated, to: url))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        for target in [url, root.appendingPathComponent("absent.ini")] {
            let link = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try SteamSettingsINI.write(generated, to: link))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        }
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
