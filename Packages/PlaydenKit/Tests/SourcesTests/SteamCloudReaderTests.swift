import XCTest
import CryptoKit
import Domain
import SteamCloudProto
import SwiftProtobuf
@testable import Sources

final class SteamCloudReaderTests: XCTestCase {
    let game = GameID(source: "steam", value: "1055540")
    let payload = Data(String(repeating: "a short hike save", count: 30).utf8)
    let zip = Data(base64Encoded: "UEsDBBQAAAAIAO28J12S2dCDGAAAAP4BAAAOAAAAc2F2ZTAubW91bnRhaW5LVCjOyC8qUcjIzE5VKE4sS00cFRg5AgBQSwECFAMUAAAACADtvCddktnQgxgAAAD+AQAADgAAAAAAAAAAAAAAgAEAAAAAc2F2ZTAubW91bnRhaW5QSwUGAAAAAAEAAQA8AAAARAAAAAAA")!
    var file: CloudFile {
        .init(name: "%WinAppDataLocalLow%adamgryu/A Short Hike/GameSaveNew.mountain",
              sha1: Data(Insecure.SHA1.hash(data: payload)), bytes: Int64(payload.count),
              modifiedAt: Date(timeIntervalSince1970: 100))
    }
    func response() -> PlaydenCloud_CCloud_ClientFileDownload_Response {
        var result = PlaydenCloud_CCloud_ClientFileDownload_Response()
        result.appid = 1055540; result.shaFile = file.sha1
        result.fileSize = UInt32(payload.count); result.rawFileSize = UInt32(payload.count)
        result.timeStamp = 100; result.useHTTPS = true
        result.urlHost = "steamcloud.example.com"; result.urlPath = "/signed/save?token=secret"
        return result
    }
    func listResponse() -> PlaydenCloud_CCloud_GetAppFileChangelist_Response {
        var result = PlaydenCloud_CCloud_GetAppFileChangelist_Response()
        result.currentChangeNumber = 27; result.isOnlyDelta = false
        result.pathPrefixes = ["%WinAppDataLocalLow%adamgryu/A Short Hike/"]
        var item = PlaydenCloud_CCloud_AppFileInfo()
        item.fileName = "GameSaveNew.mountain"; item.pathPrefixIndex = 0
        item.rawFileSize = UInt32(payload.count); item.shaFile = file.sha1; item.timeStamp = 100
        result.files = [item]; return result
    }
    func testFullListPreservesOpaqueCloudNamesAndDeletionStates() throws {
        var response = listResponse()
        var deleted = PlaydenCloud_CCloud_AppFileInfo()
        deleted.fileName = "removed"; deleted.persistState = 2
        var forgotten = deleted; forgotten.fileName = "forgotten"; forgotten.persistState = 1
        response.files += [deleted, forgotten]
        let list = try SteamCloudResponse.list(response, gameID: game, accountKey: "account-a")
        XCTAssertEqual(list.revision, 27); XCTAssertEqual(list.files[0], file)
        XCTAssertEqual(list.files[1].state, .deleted); XCTAssertEqual(list.files[2].state, .forgotten)
        XCTAssertEqual(list.files[1].name, "removed", "An absent prefix index must not select prefix zero")
        XCTAssertNotEqual(SteamCloudReader.accountKey(1), SteamCloudReader.accountKey(2))
    }
    func testIncompleteAmbiguousAndUnknownRemoteListsFailClosed() throws {
        let mutations: [(inout PlaydenCloud_CCloud_GetAppFileChangelist_Response) -> Void] = [
            { $0.isOnlyDelta = true }, { $0.clearCurrentChangeNumber() },
            { $0.files[0].pathPrefixIndex = 1 }, { $0.files[0].shaFile = Data() },
            { $0.files[0].clearRawFileSize() }, { $0.files[0].persistState = 9 },
            { $0.files[0].timeStamp = UInt64.max },
            { var duplicate = $0.files[0]; duplicate.fileName = "GAMESAVENEW.MOUNTAIN"; $0.files.append(duplicate) }
        ]
        for mutate in mutations {
            var response = listResponse(); mutate(&response)
            XCTAssertThrowsError(try SteamCloudResponse.list(response, gameID: game, accountKey: "a"))
        }
    }
    func testProtobufWireFieldsDecodeIndependentlyOfGeneratedPropertyNames() throws {
        // appid=1055540 (field 1), synced_change_number=27 (field 2).
        var request = PlaydenCloud_CCloud_GetAppFileChangelist_Request()
        request.appid = 1055540; request.syncedChangeNumber = 27
        XCTAssertEqual(try request.serializedData(), Data([0x08, 0xb4, 0xb6, 0x40, 0x10, 0x1b]))
        let list = try PlaydenCloud_CCloud_GetAppFileChangelist_Response(serializedBytes: Data([0x08, 0x1b, 0x18, 0x00]))
        XCTAssertEqual(try SteamCloudResponse.list(list, gameID: game, accountKey: "a").files, [])
    }
    func testDownloadValidatesGameIdentityHashAndTransferMetadataBeforeRequest() throws {
        let mutations: [(inout PlaydenCloud_CCloud_ClientFileDownload_Response) -> Void] = [
            { $0.appid = 2 }, { $0.clearAppid() }, { $0.shaFile = Data(repeating: 0, count: 20) },
            { $0.rawFileSize += 1 }, { $0.clearFileSize() }, { $0.encrypted = true },
            { $0.isExplicitDelete = true }, { $0.fileSize = UInt32.max }, { $0.useHTTPS = false },
            { $0.urlHost = "legit.com@unrelated.example.com" }, { $0.urlPath = "//unrelated.example.com" },
            { $0.urlHost = "unrelated.example.com/path" },
            { var header = PlaydenCloud_CCloud_ClientFileDownload_Response.HTTPHeaders(); header.name = "X-Test"; header.value = "a\r\nb"; $0.requestHeaders = [header] }
        ]
        for mutate in mutations {
            var response = response(); mutate(&response)
            XCTAssertThrowsError(try SteamCloudResponse.downloadRequest(response, appID: 1055540, expected: file))
        }
        let request = try SteamCloudResponse.downloadRequest(response(), appID: 1055540, expected: file)
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.scheme, "https")
    }
    func testPlainAndCompressedDownloadsReturnOnlyVerifiedBytes() throws {
        let plain = response()
        XCTAssertEqual(try SteamCloudResponse.downloadBody(payload, response: plain, expected: file), payload)
        var compressed = plain; compressed.fileSize = UInt32(zip.count)
        XCTAssertEqual(try SteamCloudResponse.downloadBody(zip, response: compressed, expected: file), payload)
        var damaged = payload; damaged[0] ^= 1
        XCTAssertThrowsError(try SteamCloudResponse.downloadBody(damaged, response: plain, expected: file))
        XCTAssertThrowsError(try SteamCloudResponse.downloadBody(payload.dropLast(), response: plain, expected: file))
    }
    func testEmptyCompressedSaveIsValid() throws {
        let emptyZIP = Data(base64Encoded: "UEsDBBQAAAAIAJq9J10AAAAAAgAAAAAAAAAFAAAAZW1wdHkDAFBLAQIUAxQAAAAIAJq9J10AAAAAAgAAAAAAAAAFAAAAAAAAAAAAAACAAQAAAABlbXB0eVBLBQYAAAAAAQABADMAAAAlAAAAAAA=")!
        XCTAssertEqual(try CloudZIP.extract(emptyZIP, expectedBytes: 0), Data())
    }
    func testMalformedZIPCannotAllocateFromUntrustedSizesOrReadOutsideBuffer() throws {
        for count in 0..<zip.count {
            XCTAssertThrowsError(try CloudZIP.extract(zip.prefix(count), expectedBytes: payload.count))
        }
        let mutations: [(inout Data) -> Void] = [
            { $0[0] = 0 }, // wrong local signature
            { $0[$0.count - 12] = 2 }, // more than one entry
            { $0[68 + 24] ^= 1 }, // wrong expanded size
            { for i in 68 + 42..<68 + 46 { $0[i] = 255 } }, // overflowing local offset
            { for i in 68 + 20..<68 + 24 { $0[i] = 255 } }, // oversized compressed payload
            { $0[68 + 8] = 1 }, // encrypted ZIP
        ]
        for mutate in mutations {
            var data = zip; mutate(&data)
            XCTAssertThrowsError(try CloudZIP.extract(data, expectedBytes: payload.count))
        }
        XCTAssertThrowsError(try CloudZIP.extract(zip, expectedBytes: Int.max))
    }
}
