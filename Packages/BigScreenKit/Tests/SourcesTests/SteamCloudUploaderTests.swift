import XCTest
import CryptoKit
import Domain
import SteamCloudProto
import SwiftProtobuf
@testable import Sources

private enum BatchProblem: Error, Sendable { case checkpoint, transfer }
private actor BatchFixture: CloudWriteRPC {
    enum Mode: Sendable { case success, changedBeforeBegin, unexpectedReservation, declinedCommit, changedAfterCommit }
    let mode: Mode
    let upload: CloudUpload
    let list: CloudFileList
    var events: [String] = []
    var requests: [URLRequest] = []
    var listings = 0
    init(mode: Mode = .success) {
        self.mode = mode
        let data = Data("new save".utf8)
        upload = CloudUpload(file: .init(name: "save.dat", sha1: Data(Insecure.SHA1.hash(data: data)), bytes: Int64(data.count),
            modifiedAt: Date(timeIntervalSince1970: 200)), data: data)
        list = .init(gameID: .init(source: "steam", value: "1055540"), accountKey: "account-a", revision: 7,
            files: [.init(name: "save.dat", sha1: Data(repeating: 1, count: 20), bytes: 4, modifiedAt: Date(timeIntervalSince1970: 100)),
                    .init(name: "old.dat", sha1: Data(repeating: 2, count: 20), bytes: 3, modifiedAt: Date(timeIntervalSince1970: 100))])
    }
    func journal(_ batch: CloudUploadBatch) { events.append("journal:\(batch.id):\(batch.revision)") }
    func send(_ request: URLRequest) { events.append("HTTP"); requests.append(request) }
    func call<Request: Message & Sendable, Response: Message & Sendable>(_ method: String, request: Request,
                                                                       response: Response.Type) async throws -> Response {
        events.append(method)
        let data: Data
        switch method {
        case "GetAppFileChangelist":
            listings += 1
            var result = BigScreenCloud_CCloud_GetAppFileChangelist_Response()
            result.currentChangeNumber = mode == .changedBeforeBegin ? 9 : listings == 3 ? 8 : 7
            let files = listings == 3 ? [upload.file] : list.files
            result.files = files.map { file in
                var value = BigScreenCloud_CCloud_AppFileInfo()
                value.fileName = file.name; value.shaFile = file.sha1; value.rawFileSize = UInt32(file.bytes)
                value.timeStamp = UInt64(file.modifiedAt.timeIntervalSince1970); return value
            }
            if mode == .changedAfterCommit, listings == 3 { result.files[0].shaFile = Data(repeating: 0, count: 20) }
            data = try result.serializedData()
        case "BeginAppUploadBatch":
            let value = try BigScreenCloud_CCloud_BeginAppUploadBatch_Request(serializedBytes: request.serializedData())
            guard value.filesToUpload == ["save.dat"], value.filesToDelete == ["old.dat"] else { throw BatchProblem.transfer }
            var result = BigScreenCloud_CCloud_BeginAppUploadBatch_Response(); result.batchID = 55
            result.appChangeNumber = mode == .unexpectedReservation ? 9 : 8; data = try result.serializedData()
        case "ClientBeginFileUpload":
            let value = try BigScreenCloud_CCloud_ClientBeginFileUpload_Request(serializedBytes: request.serializedData())
            guard value.fileSha == upload.file.sha1, value.fileSize == upload.data.count, value.uploadBatchID == 55,
                  !value.canEncrypt, value.filename == "save.dat" else { throw BatchProblem.transfer }
            var result = BigScreenCloud_CCloud_ClientBeginFileUpload_Response()
            var block = BigScreenCloud_ClientCloudFileUploadBlockDetails()
            block.urlHost = "steamcloud.example.com"; block.urlPath = "/upload?secret=never-log"
            block.useHTTPS = true; block.httpMethod = 4; block.blockOffset = 0; block.blockLength = UInt32(upload.data.count)
            result.blockRequests = [block]; data = try result.serializedData()
        case "ClientCommitFileUpload":
            let value = try BigScreenCloud_CCloud_ClientCommitFileUpload_Request(serializedBytes: request.serializedData())
            events.append("commit:\(value.transferSucceeded)")
            var result = BigScreenCloud_CCloud_ClientCommitFileUpload_Response(); result.fileCommitted = mode != .declinedCommit
            data = try result.serializedData()
        case "ClientDeleteFile":
            let value = try BigScreenCloud_CCloud_ClientDeleteFile_Request(serializedBytes: request.serializedData())
            guard value.filename == "old.dat", value.isExplicitDelete, value.uploadBatchID == 55 else { throw BatchProblem.transfer }
            data = try BigScreenCloud_CCloud_ClientDeleteFile_Response().serializedData()
        case "CompleteAppUploadBatchBlocking":
            let value = try BigScreenCloud_CCloud_CompleteAppUploadBatch_Request(serializedBytes: request.serializedData())
            events.append("complete:\(value.batchEresult)")
            data = try BigScreenCloud_CCloud_CompleteAppUploadBatch_Response().serializedData()
        default: throw BatchProblem.transfer
        }
        return try Response(serializedBytes: data)
    }
}

final class SteamCloudUploaderTests: XCTestCase {
    func testBatchJournalsBeforeTransferCommitsThenVerifiesRemoteFiles() async throws {
        let fixture = BatchFixture()
        let result = try await SteamCloudBatchWriter(rpc: fixture, send: { await fixture.send($0) })
            .upload([fixture.upload], deleting: ["old.dat"], basedOn: fixture.list, clientID: 1, buildID: 0,
                    onBatchStarted: { await fixture.journal($0) })
        XCTAssertEqual(result.revision, 8); XCTAssertEqual(result.files.first?.sha1, fixture.upload.file.sha1)
        let events = await fixture.events
        XCTAssertEqual(events, ["GetAppFileChangelist", "BeginAppUploadBatch", "journal:55:8", "GetAppFileChangelist",
            "ClientBeginFileUpload", "HTTP", "ClientCommitFileUpload", "commit:true", "ClientDeleteFile",
            "CompleteAppUploadBatchBlocking", "complete:1", "GetAppFileChangelist"])
        let requests = await fixture.requests
        XCTAssertEqual(requests.first?.httpMethod, "PUT"); XCTAssertEqual(requests.first?.httpBody, fixture.upload.data)
    }
    func testStaleRevisionAndFailedJournalNeverTransferFiles() async throws {
        for mode in [BatchFixture.Mode.changedBeforeBegin, .unexpectedReservation, .success] {
            let fixture = BatchFixture(mode: mode)
            do {
                _ = try await SteamCloudBatchWriter(rpc: fixture, send: { await fixture.send($0) })
                    .upload([fixture.upload], deleting: ["old.dat"], basedOn: fixture.list, clientID: 1, buildID: 0,
                            onBatchStarted: { receipt in
                                await fixture.journal(receipt)
                                if mode == .success { throw BatchProblem.checkpoint }
                            })
                XCTFail("Expected upload to stop")
            } catch {}
            let events = await fixture.events
            XCTAssertFalse(events.contains("ClientBeginFileUpload")); XCTAssertFalse(events.contains("HTTP"))
            XCTAssertFalse(events.contains("complete:1"))
            if mode != .changedBeforeBegin { XCTAssertTrue(events.contains("complete:2")) }
            else { XCTAssertFalse(events.contains("BeginAppUploadBatch")) }
        }
    }
    func testFailedTransferOrCommitNeverReportsSuccessfulBatch() async throws {
        for mode in [BatchFixture.Mode.success, .declinedCommit] {
            let fixture = BatchFixture(mode: mode)
            do {
                _ = try await SteamCloudBatchWriter(rpc: fixture, send: { request in
                    await fixture.send(request)
                    if mode == .success { throw BatchProblem.transfer }
                }).upload([fixture.upload], deleting: ["old.dat"], basedOn: fixture.list, clientID: 1, buildID: 0,
                          onBatchStarted: { await fixture.journal($0) })
                XCTFail("Expected upload to fail")
            } catch {}
            let events = await fixture.events
            XCTAssertTrue(events.contains("complete:2")); XCTAssertFalse(events.contains("complete:1"))
            XCTAssertFalse(events.contains("ClientDeleteFile"))
            if mode == .success { XCTAssertTrue(events.contains("commit:false")); XCTAssertFalse(events.contains("commit:true")) }
        }
    }
    func testPostCommitMismatchRequiresReconciliationNotAnAssumedRollback() async throws {
        let fixture = BatchFixture(mode: .changedAfterCommit)
        do {
            _ = try await SteamCloudBatchWriter(rpc: fixture, send: { await fixture.send($0) })
                .upload([fixture.upload], deleting: ["old.dat"], basedOn: fixture.list, clientID: 1, buildID: 0,
                        onBatchStarted: { await fixture.journal($0) })
            XCTFail("Expected final verification to fail")
        } catch {}
        let events = await fixture.events
        XCTAssertTrue(events.contains("complete:1")); XCTAssertFalse(events.contains("complete:2"))
    }
    func testInvalidStagedDataAndUnreviewedDeletionsStopBeforeAnyRPC() async throws {
        let fixture = BatchFixture()
        for (uploads, deletes) in [([CloudUpload(file: fixture.upload.file, data: Data())], ["old.dat"]),
                                  ([fixture.upload], ["not-in-reviewed-list"]), ([fixture.upload], ["save.dat"])] {
            do {
                _ = try await SteamCloudBatchWriter(rpc: fixture, send: { await fixture.send($0) })
                    .upload(uploads, deleting: deletes, basedOn: fixture.list, clientID: 1, buildID: 0,
                            onBatchStarted: { await fixture.journal($0) })
                XCTFail("Expected preflight to fail")
            } catch {}
        }
        let events = await fixture.events; XCTAssertTrue(events.isEmpty)
    }
    func testUploadInstructionsHonorExplicitBodiesAndRejectInvalidRanges() throws {
        var block = BigScreenCloud_ClientCloudFileUploadBlockDetails()
        block.urlHost = "steamcloud.example.com"; block.urlPath = "/part"; block.useHTTPS = true
        block.httpMethod = 4; block.blockOffset = 2; block.blockLength = 3
        let payload = Data("abcdef".utf8)
        XCTAssertEqual(try SteamCloudBatchWriter.request(block, data: payload).httpBody, Data("cde".utf8))
        block.blockOffset = UInt64.max
        XCTAssertThrowsError(try SteamCloudBatchWriter.request(block, data: payload))
        block.httpMethod = 3; block.explicitBodyData = Data("<CompleteMultipartUpload/>".utf8)
        let request = try SteamCloudBatchWriter.request(block, data: payload)
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.httpBody, block.explicitBodyData)
        block.httpMethod = 999; XCTAssertThrowsError(try SteamCloudBatchWriter.request(block, data: payload))
        block.httpMethod = 1; XCTAssertThrowsError(try SteamCloudBatchWriter.request(block, data: payload))
        block.httpMethod = 3; block.useHTTPS = false; XCTAssertThrowsError(try SteamCloudBatchWriter.request(block, data: payload))
    }
}
