import Foundation
import CryptoKit
import zlib

public enum GOGError: Error, Equatable, Sendable, LocalizedError {
    case malformed(String)
    case hashMismatch(String)
    case http(status: Int, code: String?, message: String?)
    case invalidCredentials(String?)
    case noCode
    case noBuild(String)
    case unauthorized
    case network(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .malformed(let d): "GOG data is malformed: \(d)"
        case .hashMismatch(let d): "GOG data failed its integrity check: \(d)"
        case .http(let s, let c, let m): "GOG returned HTTP \(s)\(c.map { " \($0)" } ?? "")\(m.map { ": \($0)" } ?? "")"
        case .invalidCredentials(let d): "GOG rejected the sign-in\(d.map { " (\($0))" } ?? "")."
        case .noCode: "That address has no GOG sign-in code."
        case .noBuild(let os): "GOG has no \(os == "osx" ? "Mac" : "Windows") build of this game."
        case .unauthorized: "GOG refused the download link."
        case .network(let d): "GOG can’t be reached: \(d)"
        case .cancelled: "Cancelled."
        }
    }
}

/// Every client ID, secret and host GOG sign-in and downloads use. Kept in one place so a rotation is one edit.
public struct GOGClientConfig: Sendable, Equatable {
    /// The GOG Galaxy client, which gogdl, Heroic, lgogdownloader and minigalaxy all use.
    public var clientID: String
    public var clientSecret: String
    /// The page every Galaxy login ends on; its address carries the code.
    public var redirectURI: String
    public var userAgent: String

    public static let `default` = GOGClientConfig(
        clientID: "46899977096215655",
        clientSecret: "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9",
        redirectURI: "https://embed.gog.com/on_login_success?origin=client",
        userAgent: "Playden/0.1 (macOS)")

    public init(clientID: String, clientSecret: String, redirectURI: String, userAgent: String) {
        self.clientID = clientID; self.clientSecret = clientSecret; self.redirectURI = redirectURI; self.userAgent = userAgent
    }
}

public protocol GOGTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: GOGTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GOGError.malformed("non-HTTP response") }
        return (data, http)
    }
}

/// GOG's OAuth error body: `{error, error_description}`.
struct GOGErrorBody: Decodable {
    var error: String?
    var error_description: String?
}

struct GOGHTTP: Sendable {
    let config: GOGClientConfig
    let transport: any GOGTransport
    /// Waits between retries of throttled or failed requests; tests pass a no-op.
    let pause: @Sendable (Double) async throws -> Void
    var attempts = 3

    func request(_ url: URL, bearer: String? = nil, headers: [String: String] = [:],
                 accept: ClosedRange<Int> = 200...299) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        var attempt = 0
        while true {
            attempt += 1
            let data: Data, response: HTTPURLResponse
            do { (data, response) = try await transport.send(request) }
            catch is CancellationError { throw GOGError.cancelled }
            catch let error as URLError where error.code == .cancelled { throw GOGError.cancelled }
            catch let error as GOGError { throw error }
            catch {
                if attempt < attempts { try await pause(Double(attempt)); continue }
                throw GOGError.network(error.localizedDescription)
            }
            if accept.contains(response.statusCode) { return (data, response) }
            if (response.statusCode == 429 || response.statusCode >= 500), attempt < attempts {
                try await pause(Double(1 << attempt)); continue
            }
            throw Self.error(status: response.statusCode, data: data)
        }
    }

    func json<T: Decodable>(_ type: T.Type, _ url: URL, bearer: String? = nil) async throws -> T {
        let (data, _) = try await request(url, bearer: bearer)
        return try Self.decode(T.self, data)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GOGError.malformed("\(T.self): \(error)") }
    }

    static func error(status: Int, data: Data) -> GOGError {
        let body = try? JSONDecoder().decode(GOGErrorBody.self, from: data)
        if status == 400 || status == 401, body?.error == "invalid_grant" { return .invalidCredentials(body?.error_description) }
        return .http(status: status, code: body?.error, message: body?.error_description)
    }

    static func url(_ host: String, _ path: String, _ query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = host; components.path = path
        // Encode strictly: values such as `redirect_uri` hold their own `?`, `=` and `/`.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        if !query.isEmpty {
            components.percentEncodedQuery = query.map {
                "\($0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
            }.joined(separator: "&")
        }
        return components.url!
    }
}

enum GOGCodec {
    /// Inflates a zlib stream (2-byte header, deflate, Adler-32 trailer) of unknown size.
    static func inflateZlib(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw GOGError.malformed("zlib init")
        }
        defer { inflateEnd(&stream) }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var status: Int32 = Z_OK
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            repeat {
                let produced: Int = buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(out.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return out.count - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw GOGError.malformed("zlib status \(status)") }
                output.append(contentsOf: buffer[0..<produced])
                if status == Z_OK, produced == 0, stream.avail_in == 0 { throw GOGError.malformed("truncated zlib stream") }
            } while status != Z_STREAM_END
        }
        return output
    }

    /// Gen 2 manifests are zlib JSON; gen 1 manifests and fallbacks are plain JSON.
    static func maybeInflate(_ data: Data) throws -> Data {
        guard data.count > 2, data[data.startIndex] == 0x78,
              [0x01, 0x5e, 0x9c, 0xda].contains(data[data.startIndex + 1]) else { return data }
        return try inflateZlib(data)
    }

    static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// `abcdef…` → `ab/cd/abcdef…`, the CDN layout for manifests and chunks.
    static func galaxyPath(_ hash: String) -> String {
        guard !hash.contains("/"), hash.count > 4 else { return hash }
        return "\(hash.prefix(2))/\(hash.dropFirst(2).prefix(2))/\(hash)"
    }
}
