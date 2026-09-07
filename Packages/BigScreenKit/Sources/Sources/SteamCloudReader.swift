import Foundation
import CryptoKit
import Domain
import SteamCore
import SteamCloudProto

/// Reads Cloud over the signed-in CM connection; signing out cancels pending work. Keeping
/// account verification inside that connection prevents account switches from mixing saves.
public struct SteamCloudReader: CloudReading {
    private let account: SteamAccount
    public init(account: SteamAccount) { self.account = account }

    public func files(for gameID: GameID) async throws -> CloudFileList {
        let appID = try Self.appID(gameID)
        return try await account.withCM { cm in
            let rpc = SteamCloudReadRPC(cm: cm)
            return try SteamCloudResponse.list(await rpc.files(appID), gameID: gameID,
                accountKey: Self.accountKey(await cm.steamID))
        }
    }

    public func download(_ file: CloudFile, from list: CloudFileList) async throws -> Data {
        let appID = try Self.appID(list.gameID)
        guard list.files.contains(file), file.state == .present else {
            throw cloudFailure("The selected Cloud save is no longer available. Refresh and try again.")
        }
        return try await account.withCM { cm in
            guard Self.accountKey(await cm.steamID) == list.accountKey else {
                throw cloudFailure("The Steam account changed. Refresh Cloud saves before continuing.")
            }
            let rpc = SteamCloudReadRPC(cm: cm)
            let response = try await rpc.download(appID, name: file.name)
            let request = try SteamCloudResponse.downloadRequest(response, appID: appID, expected: file)
            let body = try await SteamCloudHTTP.read(request, expectedBytes: Int(response.fileSize))
            return try SteamCloudResponse.downloadBody(body, response: response, expected: file)
        }
    }

    private static func appID(_ gameID: GameID) throws -> UInt32 {
        guard gameID.source == "steam", let id = UInt32(gameID.value), id > 0 else {
            throw cloudFailure("This game has no valid Steam identity.")
        }
        return id
    }
    static func accountKey(_ steamID: UInt64) -> String {
        SHA256.hash(data: Data("steam:\(steamID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct SteamCloudReadRPC: Sendable {
    let cm: CMClient
    func files(_ appID: UInt32) async throws -> BigScreenCloud_CCloud_GetAppFileChangelist_Response {
        var request = BigScreenCloud_CCloud_GetAppFileChangelist_Request()
        request.appid = appID; request.syncedChangeNumber = 0
        return try await cm.serviceMethod("Cloud.GetAppFileChangelist#1", request: request,
            responseType: BigScreenCloud_CCloud_GetAppFileChangelist_Response.self)
    }
    func download(_ appID: UInt32, name: String) async throws -> BigScreenCloud_CCloud_ClientFileDownload_Response {
        var request = BigScreenCloud_CCloud_ClientFileDownload_Request()
        request.appid = appID; request.filename = name
        return try await cm.serviceMethod("Cloud.ClientFileDownload#1", request: request,
            responseType: BigScreenCloud_CCloud_ClientFileDownload_Response.self)
    }
}

enum SteamCloudResponse {
    // Bound allocations and network reads. Larger files need a streaming implementation, never
    // an unchecked allocation from remote metadata. A Short Hike's UFS quota is 20 MB.
    static let maximumFileBytes = 64 * 1024 * 1024

    static func list(_ response: BigScreenCloud_CCloud_GetAppFileChangelist_Response,
                     gameID: GameID, accountKey: String) throws -> CloudFileList {
        guard response.hasCurrentChangeNumber, !response.isOnlyDelta, response.files.count <= 100_000 else {
            throw cloudFailure("Steam did not return a complete Cloud save list. Retry to refresh it.")
        }
        var names = Set<String>()
        let files = try response.files.map { file -> CloudFile in
            var name = file.fileName
            if file.hasPathPrefixIndex {
                guard Int(file.pathPrefixIndex) < response.pathPrefixes.count else {
                    throw cloudFailure("A Cloud save refers to an unknown folder.")
                }
                let prefix = response.pathPrefixes[Int(file.pathPrefixIndex)]
                if !prefix.isEmpty { name = prefix + (prefix.hasSuffix("/") ? "" : "/") + name }
            }
            guard !name.isEmpty, name.utf8.count <= 4096, !name.contains("\0"),
                  names.insert(name.lowercased()).inserted,
                  file.timeStamp < 253_402_300_800 else {
                throw cloudFailure("Steam returned an invalid or ambiguous Cloud save name or timestamp.")
            }
            let state: CloudFile.State
            switch file.persistState {
            case 0: state = .present
            case 1: state = .forgotten
            case 2: state = .deleted
            default: throw cloudFailure("Steam returned an unsupported Cloud save state.")
            }
            guard state != .present || (file.hasRawFileSize && file.shaFile.count == 20) else {
                throw cloudFailure("A Cloud save is missing its size or checksum.")
            }
            return CloudFile(name: name, sha1: file.shaFile, bytes: Int64(file.rawFileSize),
                modifiedAt: Date(timeIntervalSince1970: Double(file.timeStamp)), state: state,
                requiresUpload: file.reuploadRequested)
        }
        return CloudFileList(gameID: gameID, accountKey: accountKey, revision: response.currentChangeNumber, files: files)
    }

    static func downloadRequest(_ response: BigScreenCloud_CCloud_ClientFileDownload_Response,
                                appID: UInt32, expected: CloudFile) throws -> URLRequest {
        guard response.hasAppid, response.appid == appID, response.hasFileSize, response.hasRawFileSize,
              !response.isExplicitDelete, !response.encrypted, expected.state == .present,
              response.shaFile.count == 20, response.shaFile == expected.sha1,
              Int64(response.rawFileSize) == expected.bytes,
              response.timeStamp < 253_402_300_800 else {
            throw cloudFailure("The Cloud save changed or uses an unsupported format. Refresh and try again.")
        }
        guard response.fileSize <= maximumFileBytes, response.rawFileSize <= maximumFileBytes else {
            throw cloudFailure("This Cloud save exceeds the supported 64 MB transfer size. Local saves have been kept.")
        }
        // Steam supplies signed transfer URLs/headers. Never log them or carry them over a redirect.
        guard response.useHTTPS, !response.urlHost.isEmpty,
              response.urlHost.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\@?#\r\n")) == nil,
              response.urlPath.hasPrefix("/"), !response.urlPath.hasPrefix("//"),
              var url = URLComponents(string: "https://" + response.urlHost + response.urlPath),
              url.user == nil, url.password == nil, url.fragment == nil,
              let host = url.host, !host.isEmpty, url.port == nil || url.port == 443 else {
            throw cloudFailure("Steam returned an unsupported Cloud download address.")
        }
        url.scheme = "https"
        guard let destination = url.url else { throw cloudFailure("The Cloud download address is invalid.") }
        var request = URLRequest(url: destination)
        request.httpMethod = "GET"
        for header in response.requestHeaders {
            guard !header.name.isEmpty,
                  header.name.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n:")) == nil,
                  header.value.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) == nil else {
                throw cloudFailure("Steam returned invalid Cloud download headers.")
            }
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }

    static func downloadBody(_ body: Data, response: BigScreenCloud_CCloud_ClientFileDownload_Response,
                             expected: CloudFile) throws -> Data {
        guard body.count == response.fileSize, body.count <= maximumFileBytes,
              response.rawFileSize <= maximumFileBytes else { throw cloudFailure("The Cloud download was incomplete.") }
        let result = response.fileSize == response.rawFileSize ? body : try CloudZIP.extract(body, expectedBytes: Int(response.rawFileSize))
        guard result.count == expected.bytes, Data(Insecure.SHA1.hash(data: result)) == expected.sha1 else {
            throw cloudFailure("The Cloud save failed checksum verification. Local saves have been kept.")
        }
        return result
    }
}

/// Ephemeral HTTP, bounded reads and no redirects. Neither URLs nor server bodies appear in errors.
enum SteamCloudHTTP {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    static func read(_ request: URLRequest, expectedBytes: Int) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength < 0 || response.expectedContentLength == expectedBytes else {
                throw cloudFailure("Steam could not transfer this Cloud save. Retry when connected.")
            }
            var data = Data(); data.reserveCapacity(expectedBytes)
            for try await byte in stream {
                guard data.count < expectedBytes else { throw cloudFailure("The Cloud download exceeded its declared size.") }
                data.append(byte)
            }
            guard data.count == expectedBytes else { throw cloudFailure("The Cloud download was incomplete.") }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as OperationFailure { throw error }
        catch { throw cloudFailure("The Cloud download was interrupted. Retry when connected.") }
    }
}

func cloudFailure(_ reason: String) -> OperationFailure { .init(stage: "Steam Cloud", reason: reason, output: "") }
