import Foundation

/// A launcher session. Only `refreshToken` and the account identity need to outlive the process.
public struct EpicSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var expiresAt: Date
    public var refreshToken: String
    public var refreshExpiresAt: Date
    public var accountID: String
    public var displayName: String

    public init(accessToken: String, expiresAt: Date, refreshToken: String, refreshExpiresAt: Date,
                accountID: String, displayName: String) {
        self.accessToken = accessToken; self.expiresAt = expiresAt; self.refreshToken = refreshToken
        self.refreshExpiresAt = refreshExpiresAt; self.accountID = accountID; self.displayName = displayName
    }

    /// The launcher refreshes when fewer than ten minutes remain.
    public func needsRefresh(now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < 600 }
}

public struct EpicDeviceAuthorization: Equatable, Sendable {
    public var userCode: String
    public var deviceCode: String
    public var verificationURL: URL
    /// The activation link with the code filled in; shown as a QR code.
    public var completeVerificationURL: URL
    public var expiresAt: Date
    public var interval: TimeInterval
}

struct TokenResponse: Decodable {
    var access_token: String
    var expires_in: Double?
    var refresh_token: String?
    var refresh_expires: Double?
    var account_id: String?
    var displayName: String?
}

public struct EpicAuth: Sendable {
    let http: EpicHTTP
    let now: @Sendable () -> Date

    public init(config: EpicClientConfig = .default, transport: any EpicTransport = URLSession.shared,
                pause: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                now: @escaping @Sendable () -> Date = Date.init) {
        http = EpicHTTP(config: config, transport: transport, pause: pause); self.now = now
    }

    private var tokenURL: URL { http.url(http.config.accountHost, "/account/api/oauth/token") }

    // MARK: Device-code sign-in (PRD 09 FR-EPIC-1…3)

    public func startDeviceAuthorization() async throws -> EpicDeviceAuthorization {
        struct Response: Decodable {
            var user_code: String; var device_code: String; var verification_uri: String
            var verification_uri_complete: String; var expires_in: Double; var interval: Double?
        }
        let client = try await http.json(TokenResponse.self, "POST", tokenURL, auth: .basic(http.config.deviceCode),
                                         form: ["grant_type": "client_credentials"])
        let started = now()
        let r = try await http.json(Response.self, "POST", http.url(http.config.accountHost, "/account/api/oauth/deviceAuthorization"),
                                    auth: .bearer(client.access_token), form: ["prompt": "login"])
        guard let verification = URL(string: r.verification_uri), let complete = URL(string: r.verification_uri_complete) else {
            throw EpicError.malformed("device authorization URLs")
        }
        return EpicDeviceAuthorization(userCode: r.user_code, deviceCode: r.device_code, verificationURL: verification,
                                       completeVerificationURL: complete, expiresAt: started.addingTimeInterval(r.expires_in),
                                       interval: max(r.interval ?? 10, 1))
    }

    /// Polls until the player approves, then trades the console session for a launcher one.
    public func completeDeviceAuthorization(_ authorization: EpicDeviceAuthorization) async throws -> EpicSession {
        while true {
            try Task.checkCancellation()
            guard now() < authorization.expiresAt else { throw EpicError.deviceCodeExpired }
            try await http.pause(authorization.interval)
            do {
                let console = try await http.json(TokenResponse.self, "POST", tokenURL, auth: .basic(http.config.deviceCode),
                                                  form: ["grant_type": "device_code", "device_code": authorization.deviceCode])
                return try await launcherSession(fromConsoleToken: console.access_token)
            } catch EpicError.http(_, let code?, _) where code.hasSuffix("authorization_pending") || code.hasSuffix(".not_found") {
                continue
            } catch EpicError.http(_, let code?, _) where code.hasSuffix("expired_token") || code.hasSuffix("invalid_grant") {
                throw EpicError.deviceCodeExpired
            }
        }
    }

    func launcherSession(fromConsoleToken token: String) async throws -> EpicSession {
        let result: Result<EpicSession, Error>
        do {
            let code = try await exchangeCode(accessToken: token)
            result = .success(try await redeem(["grant_type": "exchange_code", "exchange_code": code, "token_type": "eg1"]))
        } catch { result = .failure(error) }
        // The console session has done its job; don't leave it signed in.
        try? await killSession(accessToken: token)
        return try result.get()
    }

    // MARK: Launcher session

    public func refresh(_ session: EpicSession) async throws -> EpicSession {
        do { return try await redeem(["grant_type": "refresh_token", "refresh_token": session.refreshToken, "token_type": "eg1"]) }
        catch EpicError.http(let status, let code, _) where (400..<500).contains(status) { throw EpicError.invalidCredentials(code) }
    }

    /// Returns a session that is good for at least ten more minutes.
    public func valid(_ session: EpicSession) async throws -> EpicSession {
        session.needsRefresh(now: now()) ? try await refresh(session) : session
    }

    public func killSession(accessToken: String) async throws {
        _ = try await http.request("DELETE", http.url(http.config.accountHost, "/account/api/oauth/sessions/kill/\(accessToken)"),
                                   auth: .bearer(accessToken))
    }

    /// A single-use code, valid five minutes. Games receive it as `-AUTH_PASSWORD`.
    public func exchangeCode(accessToken: String) async throws -> String {
        struct Response: Decodable { var code: String }
        return try await http.json(Response.self, "GET", http.url(http.config.accountHost, "/account/api/oauth/exchange"),
                                   auth: .bearer(accessToken)).code
    }

    private func redeem(_ form: [String: String]) async throws -> EpicSession {
        let issued = now()
        let t = try await http.json(TokenResponse.self, "POST", tokenURL, auth: .basic(http.config.launcher), form: form)
        guard let refresh = t.refresh_token, let account = t.account_id else { throw EpicError.malformed("launcher token") }
        return EpicSession(accessToken: t.access_token, expiresAt: issued.addingTimeInterval(t.expires_in ?? 7200),
                           refreshToken: refresh, refreshExpiresAt: issued.addingTimeInterval(t.refresh_expires ?? 28800),
                           accountID: account, displayName: t.displayName ?? "")
    }
}
