import Foundation

/// A Galaxy session. Only `refreshToken` and the account identity need to outlive the process.
public struct GOGSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var expiresAt: Date
    public var refreshToken: String
    public var userID: String
    public var displayName: String?

    public init(accessToken: String, expiresAt: Date, refreshToken: String, userID: String, displayName: String? = nil) {
        self.accessToken = accessToken; self.expiresAt = expiresAt; self.refreshToken = refreshToken
        self.userID = userID; self.displayName = displayName
    }

    /// Refreshes when fewer than ten minutes remain, as Epic does.
    public func needsRefresh(now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < 600 }
}

struct GOGTokenResponse: Decodable {
    var access_token: String
    var expires_in: Double?
    var refresh_token: String
    var user_id: String
}

public struct GOGAuth: Sendable {
    let http: GOGHTTP
    let now: @Sendable () -> Date

    public init(config: GOGClientConfig = .default, transport: any GOGTransport = URLSession.shared,
                pause: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        http = GOGHTTP(config: config, transport: transport, pause: pause); self.now = now
    }

    /// The Galaxy login page. `redirectURI` overrides the fixed Galaxy redirect (used by the spike only).
    public func loginURL(redirectURI: String? = nil) -> URL {
        GOGHTTP.url("auth.gog.com", "/auth", [
            .init(name: "client_id", value: http.config.clientID),
            .init(name: "redirect_uri", value: redirectURI ?? http.config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "layout", value: "galaxy"),
        ])
    }

    /// Reads the code from the address a login ends on, or accepts a bare code.
    public static func code(from pasted: String) throws -> String {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: text), components.scheme != nil {
            guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw GOGError.noCode }
            return code
        }
        guard !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber || "-_.~".contains($0) }) else { throw GOGError.noCode }
        return text
    }

    public func exchange(code: String, redirectURI: String? = nil) async throws -> GOGSession {
        try await token([
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: redirectURI ?? http.config.redirectURI),
        ])
    }

    /// GOG may rotate the refresh token, so callers must store the returned session.
    public func refresh(_ session: GOGSession) async throws -> GOGSession {
        var next = try await token([
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: session.refreshToken),
        ])
        next.displayName = next.displayName ?? session.displayName
        return next
    }

    public func valid(_ session: GOGSession) async throws -> GOGSession {
        session.needsRefresh(now: now()) ? try await refresh(session) : session
    }

    /// Token calls are GETs with every parameter in the query, as every Galaxy client sends them.
    private func token(_ items: [URLQueryItem]) async throws -> GOGSession {
        let url = GOGHTTP.url("auth.gog.com", "/token", [
            .init(name: "client_id", value: http.config.clientID),
            .init(name: "client_secret", value: http.config.clientSecret),
        ] + items)
        let response = try await http.json(GOGTokenResponse.self, url)
        return GOGSession(accessToken: response.access_token, expiresAt: now().addingTimeInterval(response.expires_in ?? 3600),
                          refreshToken: response.refresh_token, userID: response.user_id)
    }
}
