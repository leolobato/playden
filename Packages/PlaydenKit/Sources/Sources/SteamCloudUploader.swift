import Foundation
import CryptoKit
import Domain
import SteamCore
import SteamCloudProto
import SwiftProtobuf

public struct SteamCloudUploader: CloudWriting {
    private let account: SteamAccount
    public init(account: SteamAccount) { self.account = account }
    public func upload(_ files: [CloudUpload], deleting: [String], basedOn list: CloudFileList,
                       clientID: UInt64, buildID: UInt64,
                       onBatchStarted: @escaping @Sendable (CloudUploadBatch) async throws -> Void) async throws -> CloudFileList {
        try await account.withCM { cm in
            guard SteamCloudReader.accountKey(await cm.steamID) == list.accountKey else {
                throw cloudFailure("The Steam account changed. Review Cloud saves before uploading.")
            }
            return try await SteamCloudBatchWriter(rpc: LiveCloudWriteRPC(cm: cm), send: SteamCloudHTTP.write)
                .upload(files, deleting: deleting, basedOn: list, clientID: clientID, buildID: buildID, onBatchStarted: onBatchStarted)
        }
    }
}

protocol CloudWriteRPC: Sendable {
    func call<Request: Message & Sendable, Response: Message & Sendable>(_ method: String, request: Request,
                                                                       response: Response.Type) async throws -> Response
}
struct LiveCloudWriteRPC: CloudWriteRPC {
    let cm: CMClient
    func call<Request: Message & Sendable, Response: Message & Sendable>(_ method: String, request: Request,
                                                                       response: Response.Type) async throws -> Response {
        try await cm.serviceMethod("Cloud." + method + "#1", request: request, responseType: response)
    }
}

struct SteamCloudBatchWriter: Sendable {
    let rpc: any CloudWriteRPC
    let send: @Sendable (URLRequest) async throws -> Void

    func upload(_ files: [CloudUpload], deleting: [String], basedOn list: CloudFileList,
                clientID: UInt64, buildID: UInt64,
                onBatchStarted: @escaping @Sendable (CloudUploadBatch) async throws -> Void) async throws -> CloudFileList {
        guard list.gameID.source == "steam", let appID = UInt32(list.gameID.value), appID > 0, clientID != 0 else {
            throw cloudFailure("The Cloud upload identity is invalid.")
        }
        var names = Set<String>()
        for upload in files {
            let file = upload.file, time = file.modifiedAt.timeIntervalSince1970
            guard validName(file.name), names.insert(file.name.lowercased()).inserted, file.state == .present,
                  upload.data.count <= SteamCloudResponse.maximumFileBytes, file.bytes == upload.data.count,
                  Data(Insecure.SHA1.hash(data: upload.data)) == file.sha1,
                  time.isFinite, time >= 0, time < 253_402_300_800 else { throw cloudFailure("A staged Cloud upload failed validation.") }
        }
        for name in deleting {
            guard validName(name), names.insert(name.lowercased()).inserted,
                  list.files.contains(where: { $0.name == name && $0.state == .present }) else {
                throw cloudFailure("A Cloud deletion does not match the reviewed remote save list.")
            }
        }
        let current = try await fetch(list)
        guard current.revision == list.revision, sameFiles(current.files, list.files) else { throw changed() }
        if files.isEmpty && deleting.isEmpty { return current }
        var begin = BigScreenCloud_CCloud_BeginAppUploadBatch_Request()
        begin.appid = appID; begin.clientID = clientID; begin.appBuildID = buildID; begin.machineName = "Playden"
        begin.filesToUpload = files.map { $0.file.name }; begin.filesToDelete = deleting
        let batch = try await rpc.call("BeginAppUploadBatch", request: begin, response: BigScreenCloud_CCloud_BeginAppUploadBatch_Response.self)
        guard batch.hasBatchID, batch.batchID != 0 else { throw cloudFailure("Steam did not provide an upload batch receipt.") }
        var completed = false
        do {
            // Journal first, including unexpected revisions, so recovery knows the reserved batch.
            try await onBatchStarted(.init(id: batch.batchID, revision: batch.appChangeNumber))
            guard batch.hasAppChangeNumber, list.revision < UInt64.max,
                  batch.appChangeNumber == list.revision + 1 else { throw changed() }
            let checked = try await fetch(list)
            guard [list.revision, batch.appChangeNumber].contains(checked.revision), sameFiles(checked.files, list.files) else { throw changed() }
            for upload in files {
                try Task.checkCancellation()
                try await transfer(upload, appID: appID, batchID: batch.batchID)
            }
            for name in deleting {
                try Task.checkCancellation()
                var request = BigScreenCloud_CCloud_ClientDeleteFile_Request()
                request.appid = appID; request.filename = name; request.isExplicitDelete = true; request.uploadBatchID = batch.batchID
                _ = try await rpc.call("ClientDeleteFile", request: request, response: BigScreenCloud_CCloud_ClientDeleteFile_Response.self)
            }
            try Task.checkCancellation()
            try await finish(appID, batchID: batch.batchID, success: true); completed = true
            let after = try await fetch(list)
            var expected = list.files.filter { $0.state == .present && !names.contains($0.name.lowercased()) }
            expected += files.map(\.file)
            guard after.revision == batch.appChangeNumber, fingerprints(after.files) == fingerprints(expected) else {
                throw cloudFailure("The uploaded Cloud files could not be verified. Keep local saves and retry synchronization.")
            }
            return after
        } catch {
            if !completed { try? await finish(appID, batchID: batch.batchID, success: false) }
            throw error
        }
    }
    private func transfer(_ upload: CloudUpload, appID: UInt32, batchID: UInt64) async throws {
        var begin = BigScreenCloud_CCloud_ClientBeginFileUpload_Request()
        begin.appid = appID; begin.filename = upload.file.name
        begin.fileSize = UInt32(upload.data.count); begin.rawFileSize = begin.fileSize
        begin.fileSha = upload.file.sha1; begin.timeStamp = UInt64(upload.file.modifiedAt.timeIntervalSince1970)
        begin.uploadBatchID = batchID; begin.canEncrypt = false
        let response = try await rpc.call("ClientBeginFileUpload", request: begin, response: BigScreenCloud_CCloud_ClientBeginFileUpload_Response.self)
        guard !response.encryptFile else { throw cloudFailure("Steam requested an unsupported encrypted Cloud upload.") }
        guard response.blockRequests.count <= 512,
              response.blockRequests.reduce(UInt64(0), { $0 + UInt64($1.hasExplicitBodyData ? $1.explicitBodyData.count : Int($1.blockLength)) }) <= UInt64(SteamCloudResponse.maximumFileBytes) * 2 else {
            throw cloudFailure("Steam requested an unsupported Cloud upload block layout.")
        }
        let requests = try response.blockRequests.map { try Self.request($0, data: upload.data) }
        do {
            for request in requests { try Task.checkCancellation(); try await send(request) }
        } catch {
            try? await commit(upload, appID: appID, success: false)
            throw error
        }
        try Task.checkCancellation()
        try await commit(upload, appID: appID, success: true)
    }
    private func commit(_ upload: CloudUpload, appID: UInt32, success: Bool) async throws {
        var request = BigScreenCloud_CCloud_ClientCommitFileUpload_Request()
        request.appid = appID; request.filename = upload.file.name; request.fileSha = upload.file.sha1; request.transferSucceeded = success
        let response = try await rpc.call("ClientCommitFileUpload", request: request, response: BigScreenCloud_CCloud_ClientCommitFileUpload_Response.self)
        guard !success || response.fileCommitted else { throw cloudFailure("Steam did not commit this Cloud save. Local saves have been kept.") }
    }
    private func finish(_ appID: UInt32, batchID: UInt64, success: Bool) async throws {
        var request = BigScreenCloud_CCloud_CompleteAppUploadBatch_Request()
        request.appid = appID; request.batchID = batchID; request.batchEresult = success ? 1 : 2
        _ = try await rpc.call("CompleteAppUploadBatchBlocking", request: request, response: BigScreenCloud_CCloud_CompleteAppUploadBatch_Response.self)
    }
    private func fetch(_ expected: CloudFileList) async throws -> CloudFileList {
        var request = BigScreenCloud_CCloud_GetAppFileChangelist_Request()
        request.appid = UInt32(expected.gameID.value)!; request.syncedChangeNumber = 0
        let response = try await rpc.call("GetAppFileChangelist", request: request, response: BigScreenCloud_CCloud_GetAppFileChangelist_Response.self)
        return try SteamCloudResponse.list(response, gameID: expected.gameID, accountKey: expected.accountKey)
    }
    static func request(_ block: BigScreenCloud_ClientCloudFileUploadBlockDetails, data: Data) throws -> URLRequest {
        var request = try SteamCloudResponse.transferRequest(host: block.urlHost, path: block.urlPath,
            https: block.useHTTPS, headers: block.requestHeaders.map { ($0.name, $0.value) })
        let methods: [Int32: String] = [1: "GET", 2: "HEAD", 3: "POST", 4: "PUT", 5: "DELETE", 6: "OPTIONS", 7: "PATCH"]
        guard let method = methods[block.httpMethod] else { throw cloudFailure("Steam requested an unsupported Cloud upload method.") }
        request.httpMethod = method
        if block.hasExplicitBodyData {
            guard block.explicitBodyData.count <= SteamCloudResponse.maximumFileBytes else { throw cloudFailure("A Cloud upload instruction is too large.") }
            request.httpBody = block.explicitBodyData
        } else {
            guard block.blockOffset <= data.count, UInt64(block.blockLength) <= UInt64(data.count) - block.blockOffset else {
                throw cloudFailure("Steam requested a Cloud upload block outside the staged file.")
            }
            let offset = Int(block.blockOffset)
            request.httpBody = data.subdata(in: offset..<offset + Int(block.blockLength))
        }
        guard !["GET", "HEAD"].contains(method) || request.httpBody?.isEmpty != false else {
            throw cloudFailure("Steam requested an invalid Cloud upload body.")
        }
        return request
    }
    private func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 4096 && !name.contains(where: { $0 == "\0" || $0.isNewline })
    }
    private func sameFiles(_ lhs: [CloudFile], _ rhs: [CloudFile]) -> Bool { lhs.sorted { $0.name < $1.name } == rhs.sorted { $0.name < $1.name } }
    private struct Fingerprint: Equatable { let sha1: Data; let bytes: Int64 }
    private func fingerprints(_ files: [CloudFile]) -> [String: Fingerprint] {
        files.filter { $0.state == .present }.reduce(into: [:]) { $0[$1.name] = .init(sha1: $1.sha1, bytes: $1.bytes) }
    }
    private func changed() -> OperationFailure { cloudFailure("Cloud saves changed before upload. Refresh and resolve differences before trying again.") }
}
