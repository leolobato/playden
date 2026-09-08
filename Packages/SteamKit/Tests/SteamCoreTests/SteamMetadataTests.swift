import XCTest
import SwiftProtobuf
import SteamProto
@testable import SteamCore

final class SteamMetadataTests: XCTestCase {
    func testEncryptedTicketResponseFixtureSerializesWholeTicket() throws {
        var ticket = EncryptedAppTicket()
        ticket.ticketVersionNo = 4
        ticket.crcEncryptedticket = 0x1234
        ticket.cbEncrypteduserdata = 2
        ticket.cbEncryptedAppownershipticket = 3
        ticket.encryptedTicket = Data([0xaa, 0xbb, 0xcc])
        var response = CMsgClientRequestEncryptedAppTicketResponse()
        response.appID = 3_373_660
        response.eresult = 1
        response.encryptedAppTicket = ticket
        let decoded = try CMClient.decodeEncryptedAppTicketResponse(
            response.serializedData(), expectedAppID: 3_373_660)
        XCTAssertEqual(decoded, try ticket.serializedData())
        XCTAssertEqual(decoded.base64EncodedString(), try ticket.serializedData().base64EncodedString())
    }

    func testUserStatsResponseFixture() throws {
        var stat = CMsgClientGetUserStatsResponse.Stats()
        stat.statID = 20; stat.statValue = 42
        var block = CMsgClientGetUserStatsResponse.Achievement_Blocks()
        block.achievementID = 10; block.unlockTime = [0, 123]
        var response = CMsgClientGetUserStatsResponse()
        response.gameID = 3_373_660
        response.eresult = 1
        response.crcStats = 99
        response.schema = Data([0x08])
        response.stats = [stat]
        response.achievementBlocks = [block]
        let decoded = try CMClient.decodeUserStatsResponse(response.serializedData(), expectedAppID: 3_373_660)
        XCTAssertEqual(decoded.appID, 3_373_660)
        XCTAssertEqual(decoded.crc, 99)
        XCTAssertEqual(decoded.schema, Data([0x08]))
        XCTAssertEqual(decoded.stats.first?.id, 20)
        XCTAssertEqual(decoded.stats.first?.value, 42)
        XCTAssertEqual(decoded.achievementBlocks.first?.unlockTimes, [0, 123])
    }

    func testEncryptedTicketCacheUsesThirtyMinuteFixtureWindow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bigscreen-ticket-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EncryptedAppTicketCache(directory: directory)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var fetches = 0
        let first = try await cache.ticket(appID: 10, now: base) {
            fetches += 1
            return Data([1])
        }
        let cached = try await cache.ticket(appID: 10, now: base.addingTimeInterval(1_799)) {
            fetches += 1
            return Data([2])
        }
        let refreshed = try await cache.ticket(appID: 10, now: base.addingTimeInterval(1_800)) {
            fetches += 1
            return Data([3])
        }
        XCTAssertEqual(first, Data([1]))
        XCTAssertEqual(cached, Data([1]))
        XCTAssertEqual(refreshed, Data([3]))
        XCTAssertEqual(fetches, 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
