import Foundation
import SwiftProtobuf

/// Thin client for api.steampowered.com, in both flavors we need:
/// protobuf-encoded service calls (IAuthenticationService) and plain JSON calls.
public enum SteamWebAPI {
    public static let base = "https://api.steampowered.com"
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    /// Calls a protobuf web API method. GET when `post` is false.
    /// Returns the decoded response and the X-eresult header value.
    public static func callProto<Req: Message, Resp: Message>(
        interface: String, method: String, version: Int = 1,
        request: Req, responseType: Resp.Type,
        accessToken: String? = nil, post: Bool = true
    ) async throws -> (Resp, EResult) {
        let input = try request.serializedData().base64EncodedString()
        var urlString = "\(base)/\(interface)/\(method)/v\(version)/"
        var queryParts: [String] = []
        if let accessToken { queryParts.append("access_token=\(percentEncode(accessToken))") }

        var req: URLRequest
        if post {
            if !queryParts.isEmpty { urlString += "?" + queryParts.joined(separator: "&") }
            req = URLRequest(url: URL(string: urlString)!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = "input_protobuf_encoded=\(percentEncode(input))".data(using: .utf8)
        } else {
            queryParts.append("input_protobuf_encoded=\(percentEncode(input))")
            urlString += "?" + queryParts.joined(separator: "&")
            req = URLRequest(url: URL(string: urlString)!)
        }
        req.setValue("Playden/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SteamError.protocolError("no HTTP response") }
        guard http.statusCode == 200 else { throw SteamError.http(status: http.statusCode, url: "\(base)/\(interface)/\(method)/v\(version)/") }
        let eresult = EResult(rawValue: Int32(http.value(forHTTPHeaderField: "x-eresult") ?? "1") ?? 1)
        let resp = try Resp(serializedBytes: data)
        return (resp, eresult)
    }

    /// Plain JSON web API call (e.g. GetOwnedGames, GetCMListForConnect).
    public static func callJSON(
        interface: String, method: String, version: Int = 1,
        params: [String: String]
    ) async throws -> [String: Any] {
        var parts = params.map { "\($0.key)=\(percentEncode($0.value))" }
        parts.append("format=json")
        let urlString = "\(base)/\(interface)/\(method)/v\(version)/?" + parts.joined(separator: "&")
        var req = URLRequest(url: URL(string: urlString)!)
        req.setValue("Playden/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SteamError.protocolError("no HTTP response") }
        guard http.statusCode == 200 else { throw SteamError.http(status: http.statusCode, url: "\(base)/\(interface)/\(method)/v\(version)/") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SteamError.protocolError("non-object JSON from \(method)")
        }
        return json
    }

    static func percentEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
