import XCTest
import Foundation
import CryptoKit
import Domain
@testable import Sources

final class SteamSaveValidationTests: XCTestCase {
    private let filename = "GameSaveNew.mountain"
    private func i(_ value: Int32) -> Data {
        var little = value.littleEndian; return withUnsafeBytes(of: &little) { Data($0) }
    }
    private func string(_ value: String) -> Data {
        let bytes = Data(value.utf8); var count = bytes.count, prefix = Data()
        repeat { prefix.append(UInt8(count & 127) | (count >= 128 ? 128 : 0)); count >>= 7 } while count != 0
        return prefix + bytes
    }
    private func ref(_ id: Int32) -> Data { Data([9]) + i(id) }
    private func object(_ id: Int32, _ name: String, names: [String], kinds: [UInt8], extra: [UInt8] = [], values: Data, system: Bool = false) -> Data {
        Data([system ? 4 : 5]) + i(id) + string(name) + i(Int32(names.count)) + names.reduce(Data()) { $0 + string($1) } + Data(kinds) + Data(extra) + (system ? Data() : i(2)) + values
    }
    private func fixture(listSize: Int32 = 0, dictionarySize: Int32 = 0, arrayLength: Int32 = 0, filenameID: Int32 = 10) -> Data {
        let dictionary = "System.Collections.Generic.Dictionary`2[[System.String, mscorlib],[System.String, mscorlib]]"
        let list = "System.Collections.Generic.List`1[[System.String, mscorlib]]"
        var data = Data([0]) + i(1) + i(-1) + i(1) + i(0)
        data += Data([12]) + i(2) + string("Assembly-CSharp, Version=0.0.0.0")
        data += object(1, "GlobalData+GameData", names: ["fileName", "tags", "inventory", "playerReplayData", "allCollectedNames"], kinds: [1, 2, 2, 2, 2], values: ref(filenameID) + ref(11) + ref(12) + ref(13) + ref(14))
        data += Data([6]) + i(10) + string(filename)
        data += object(11, "Tags", names: ["bools", "ints", "floats", "strings"], kinds: [2, 2, 2, 2], values: ref(13) + ref(13) + ref(13) + ref(13))
        data += object(12, "GlobalData+CollectionInventory", names: [], kinds: [], values: Data())
        data += object(13, dictionary, names: ["HashSize"], kinds: [0], extra: [8], values: i(dictionarySize), system: true)
        data += object(14, list, names: ["_items", "_size", "_version"], kinds: [6, 0, 0], extra: [8, 8], values: ref(15) + i(listSize) + i(0), system: true)
        data += Data([17]) + i(15) + i(arrayLength) + Data([11])
        return data
    }
    private func installed(_ app: String = "1055540") -> InstallationRecord {
        .init(game: .init(id: .init(source: "steam", value: app), title: "Fixture"),
            location: .init(volumeID: "fixture", lastKnownRoot: URL(fileURLWithPath: "/fixture"), relativePath: "game"),
            bottleID: "playden-steam-" + app, manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: 1)
    }
    private func session(_ installed: InstallationRecord, forced: Bool = false, exit: Int32 = 0, finished: Bool = true) -> PlaySessionRecord {
        var value = PlaySessionRecord(gameID: installed.gameID, bottleID: installed.bottleID)
        value.runtime = .init(run: .init(bottle: .init(gameID: installed.gameID, name: installed.bottleID, ownershipToken: installed.ownershipToken),
            launcher: .init(pid: 100, startSeconds: 1, startMicroseconds: 0)), phase: .exited, hadWindow: true, exitCode: exit, forced: forced)
        if finished { value.endedAt = value.startedAt; value.outcome = forced ? .forced : exit == 0 ? .clean : .crash }
        return value
    }
    private func upload(_ data: Data) -> CloudUpload {
        .init(file: .init(name: "%WinAppDataLocalLow%adamgryu/A Short Hike/" + filename,
            sha1: Data(Insecure.SHA1.hash(data: data)), bytes: Int64(data.count), modifiedAt: .now), data: data)
    }

    func testCompleteGraphValidatesAfterCrashAndForcedExitWithoutChangingBytes() throws {
        let data = fixture(), installed = installed()
        for prior in [nil, session(installed, forced: true), session(installed, exit: 2)] {
            XCTAssertNoThrow(try SteamSaveValidation.validate(installed, uploads: [upload(data)], deleting: [], previousSession: prior))
        }
        XCTAssertEqual(data, fixture())
    }
    func testEveryTruncatedPrefixAndTrailingDataAreRejected() {
        let data = fixture()
        for count in 0..<data.count {
            XCTAssertThrowsError(try ShortHikeSaveValidator.validate(data.prefix(count), filename: filename), "Accepted prefix of \(count) bytes")
        }
        XCTAssertThrowsError(try ShortHikeSaveValidator.validate(data + Data([0]), filename: filename))
    }
    func testInvalidReferencesDuplicateIdsAndRootIdentityAreRejected() {
        XCTAssertThrowsError(try ShortHikeSaveValidator.validate(fixture(filenameID: 999), filename: filename))
        var duplicate = fixture(); duplicate.removeLast(); duplicate += Data([6]) + i(10) + string("duplicate") + Data([11])
        XCTAssertThrowsError(try ShortHikeSaveValidator.validate(duplicate, filename: filename))
        XCTAssertThrowsError(try ShortHikeSaveValidator.validate(fixture(), filename: "other.mountain"))
        var wrong = fixture()
        if let range = wrong.range(of: Data("GlobalData+GameData".utf8)) { wrong.replaceSubrange(range, with: Data("GlobalData+FakeData".utf8)) }
        XCTAssertThrowsError(try ShortHikeSaveValidator.validate(wrong, filename: filename))
        for (kind, extra) in [(UInt8(1), [UInt8]()), (UInt8(3), Array(string("Dummy[]")))] {
            var data = fixture(); data.removeLast()
            data += object(100, "Extra", names: ["slot"], kinds: [kind], extra: extra, values: ref(13)) + Data([11])
            XCTAssertThrowsError(try ShortHikeSaveValidator.validate(data, filename: filename))
        }
    }
    func testCollectionLengthsOversizedCountsAndBadPrimitiveValuesAreRejected() {
        for data in [fixture(listSize: -1), fixture(listSize: 1), fixture(dictionarySize: 1), fixture(arrayLength: -1), fixture(arrayLength: 1_000_001)] {
            XCTAssertThrowsError(try ShortHikeSaveValidator.validate(data, filename: filename))
        }
        for (type, bytes) in [(UInt8(1), Data([2])), (UInt8(11), i(Int32(bitPattern: 0x7FC00000)))] {
            var data = fixture(); data.removeLast()
            data += object(100, "Extra", names: ["value"], kinds: [0], extra: [type], values: bytes) + Data([11])
            XCTAssertThrowsError(try ShortHikeSaveValidator.validate(data, filename: filename))
        }
        var overflow = Data([0]) + i(1) + i(-1) + i(1) + i(0)
        overflow += Data([12]) + i(2) + Data(repeating: 255, count: 5)
        XCTAssertThrowsError(try ShortHikeSaveValidator.validate(overflow, filename: filename))
    }
    func testUnknownFormatsRequireAnOwnedCleanExitAndDeletionsCannotBypassValidation() throws {
        let installed = installed("other"), payload = upload(Data("opaque save".utf8))
        XCTAssertThrowsError(try SteamSaveValidation.validate(installed, uploads: [payload], deleting: [], previousSession: nil))
        XCTAssertThrowsError(try SteamSaveValidation.validate(installed, uploads: [payload], deleting: [], previousSession: session(installed, forced: true)))
        XCTAssertNoThrow(try SteamSaveValidation.validate(installed, uploads: [payload], deleting: [], previousSession: session(installed, finished: false)))
        var changed = installed; changed.ownershipToken = UUID()
        XCTAssertThrowsError(try SteamSaveValidation.validate(changed, uploads: [payload], deleting: [], previousSession: session(installed)))
        let hike = self.installed()
        for files in [[CloudUpload](), [upload(fixture())]] {
            XCTAssertThrowsError(try SteamSaveValidation.validate(hike, uploads: files, deleting: ["old.mountain"], previousSession: session(hike, forced: true)))
        }
        XCTAssertNoThrow(try SteamSaveValidation.validate(hike, uploads: [], deleting: ["old.mountain"], previousSession: session(hike)))
    }
    func testChangedStagingAndInvalidStructureAreRejectedEvenAfterCleanExit() {
        let installed = installed(), source = upload(fixture())
        let changed = CloudUpload(file: source.file, data: source.data + Data([0]))
        XCTAssertThrowsError(try SteamSaveValidation.validate(installed, uploads: [changed], deleting: [], previousSession: session(installed)))
        XCTAssertThrowsError(try SteamSaveValidation.validate(installed, uploads: [upload(Data([0, 1]))], deleting: [], previousSession: session(installed)))
    }
    func testPreservedAcceptanceTitleCopiesWhenExplicitlyProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let local = environment["PLAYDEN_SHORT_HIKE_LOCAL_SAVE"], let remote = environment["PLAYDEN_SHORT_HIKE_CLOUD_SAVE"] else {
            throw XCTSkip("Set the two PLAYDEN_SHORT_HIKE_*_SAVE paths to test private preserved copies read-only")
        }
        for path in [local, remote] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try ShortHikeSaveValidator.validate(data, filename: filename)
            for count in [0, 17, 50, data.count / 2, data.count - 1] {
                XCTAssertThrowsError(try ShortHikeSaveValidator.validate(data.prefix(count), filename: filename))
            }
            let installed = installed()
            try SteamSaveValidation.validate(installed, uploads: [upload(data)], deleting: [], previousSession: session(installed, forced: true))
        }
    }
}
