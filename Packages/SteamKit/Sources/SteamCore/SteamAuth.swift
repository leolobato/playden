import Foundation
import SteamProto

/// What the UI must supply when Steam Guard interposes.
public enum GuardPrompt: Sendable {
    case deviceCode        // code from the Steam mobile app
    case emailCode(String) // code sent to email (associated domain)
}

public enum AuthEvent: Sendable {
    case waitingForDeviceConfirmation  // user must approve in the Steam mobile app
    case qrChallenge(String)           // (re)display this challenge URL as a QR code
}

/// Login flows against IAuthenticationService (plain HTTPS + protobuf).
/// Both yield a refresh token usable for CM logon and an access token for web calls.
public enum SteamAuth {
    static let platformDeviceName = "Big Screen (macOS)"

    static func deviceDetails(named name: String) -> CAuthentication_DeviceDetails {
        var d = CAuthentication_DeviceDetails()
        d.deviceFriendlyName = name
        d.platformType = .kEauthTokenPlatformTypeSteamClient
        d.osType = 0  // EOSType.WinUnknown — pose as Windows everywhere (doc 04 §4)
        return d
    }

    // MARK: password + Steam Guard

    public static func loginWithPassword(
        accountName: String,
        password: String,
        guardData: String? = nil,
        deviceName: String = "Big Screen (macOS)",
        codeProvider: @escaping @Sendable (GuardPrompt) async throws -> String,
        onEvent: @escaping @Sendable (AuthEvent) -> Void = { _ in }
    ) async throws -> StoredAuth {
        var rsaReq = CAuthentication_GetPasswordRSAPublicKey_Request()
        rsaReq.accountName = accountName
        let (rsa, rsaResult) = try await SteamWebAPI.callProto(
            interface: "IAuthenticationService", method: "GetPasswordRSAPublicKey",
            request: rsaReq, responseType: CAuthentication_GetPasswordRSAPublicKey_Response.self, post: false)
        guard rsaResult == .ok else { throw SteamError.eresult(rsaResult, context: "GetPasswordRSAPublicKey") }

        let encrypted = try SteamCrypto.rsaEncryptPKCS1(
            message: Data(password.utf8), modulusHex: rsa.publickeyMod, exponentHex: rsa.publickeyExp)

        var begin = CAuthentication_BeginAuthSessionViaCredentials_Request()
        begin.accountName = accountName
        begin.encryptedPassword = encrypted.base64EncodedString()
        begin.encryptionTimestamp = rsa.timestamp
        begin.persistence = .kEsessionPersistencePersistent
        begin.websiteID = "Client"
        begin.deviceDetails = deviceDetails(named: deviceName)
        if let guardData { begin.guardData = guardData }

        let (session, beginResult) = try await SteamWebAPI.callProto(
            interface: "IAuthenticationService", method: "BeginAuthSessionViaCredentials",
            request: begin, responseType: CAuthentication_BeginAuthSessionViaCredentials_Response.self)
        switch beginResult {
        case .ok: break
        case .invalidPassword: throw SteamError.authFailed("invalid password or account name")
        case .accountLoginDeniedThrottle, .rateLimitExceeded:
            throw SteamError.authFailed("login throttled by Steam — wait a while and retry")
        default: throw SteamError.eresult(beginResult, context: "BeginAuthSessionViaCredentials")
        }

        // Satisfy Steam Guard. Preference order: device confirmation (just poll),
        // device code, email code.
        let confirmations = session.allowedConfirmations.map(\.confirmationType)
        if confirmations.contains(.kEauthSessionGuardTypeDeviceConfirmation) {
            onEvent(.waitingForDeviceConfirmation)
        } else if confirmations.contains(.kEauthSessionGuardTypeDeviceCode) ||
                  confirmations.contains(.kEauthSessionGuardTypeEmailCode) {
            let isDevice = confirmations.contains(.kEauthSessionGuardTypeDeviceCode)
            let domain = session.allowedConfirmations
                .first { $0.confirmationType == .kEauthSessionGuardTypeEmailCode }?.associatedMessage ?? ""
            let code = try await codeProvider(isDevice ? .deviceCode : .emailCode(domain))
            var update = CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request()
            update.clientID = session.clientID
            update.steamid = session.steamid
            update.code = code
            update.codeType = isDevice ? .kEauthSessionGuardTypeDeviceCode : .kEauthSessionGuardTypeEmailCode
            let (_, updResult) = try await SteamWebAPI.callProto(
                interface: "IAuthenticationService", method: "UpdateAuthSessionWithSteamGuardCode",
                request: update, responseType: CAuthentication_UpdateAuthSessionWithSteamGuardCode_Response.self)
            guard updResult == .ok || updResult == .duplicateRequest else {
                throw SteamError.eresult(updResult, context: "Steam Guard code rejected")
            }
        }
        // .kEauthSessionGuardTypeNone → just poll.

        return try await poll(clientID: session.clientID, requestID: session.requestID,
                              interval: session.interval, fallbackSteamID: session.steamid, onEvent: onEvent)
    }

    // MARK: QR

    public static func loginWithQR(
        deviceName: String = "Big Screen (macOS)",
        onEvent: @escaping @Sendable (AuthEvent) -> Void
    ) async throws -> StoredAuth {
        var begin = CAuthentication_BeginAuthSessionViaQR_Request()
        begin.deviceDetails = deviceDetails(named: deviceName)
        begin.websiteID = "Client"
        let (session, beginResult) = try await SteamWebAPI.callProto(
            interface: "IAuthenticationService", method: "BeginAuthSessionViaQR",
            request: begin, responseType: CAuthentication_BeginAuthSessionViaQR_Response.self)
        guard beginResult == .ok else { throw SteamError.eresult(beginResult, context: "BeginAuthSessionViaQR") }
        onEvent(.qrChallenge(session.challengeURL))
        return try await poll(clientID: session.clientID, requestID: session.requestID,
                              interval: session.interval, fallbackSteamID: 0, onEvent: onEvent)
    }

    // MARK: polling

    static func poll(
        clientID: UInt64, requestID: Data, interval: Float, fallbackSteamID: UInt64,
        onEvent: @escaping @Sendable (AuthEvent) -> Void
    ) async throws -> StoredAuth {
        var clientID = clientID
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
            var req = CAuthentication_PollAuthSessionStatus_Request()
            req.clientID = clientID
            req.requestID = requestID
            let (resp, result) = try await SteamWebAPI.callProto(
                interface: "IAuthenticationService", method: "PollAuthSessionStatus",
                request: req, responseType: CAuthentication_PollAuthSessionStatus_Response.self)
            switch result {
            case .ok: break
            case .expired, .fileNotFound:
                throw SteamError.authSessionExpired
            default:
                throw SteamError.eresult(result, context: "PollAuthSessionStatus")
            }
            if resp.hasNewClientID { clientID = resp.newClientID }
            if resp.hasNewChallengeURL { onEvent(.qrChallenge(resp.newChallengeURL)) }
            if !resp.refreshToken.isEmpty {
                let steamID = JWT.steamID(resp.refreshToken) ?? fallbackSteamID
                return StoredAuth(
                    accountName: resp.accountName,
                    steamID: steamID,
                    refreshToken: resp.refreshToken,
                    accessToken: resp.accessToken.isEmpty ? nil : resp.accessToken,
                    guardData: resp.hasNewGuardData ? resp.newGuardData : nil)
            }
        }
        throw SteamError.authSessionExpired
    }

    // MARK: access token renewal

    /// Returns a valid (renewing if needed) access token for web API calls, updating the store.
    public static func validAccessToken(_ auth: inout StoredAuth,
                                        store: any AuthCredentialStore = FileAuthCredentialStore()) async throws -> String {
        try await validAccessToken(&auth, store: store, generate: generateAccessToken)
    }

    static func validAccessToken(_ auth: inout StoredAuth, store: any AuthCredentialStore,
                                 generate: @Sendable (StoredAuth) async throws -> String) async throws -> String {
        if let token = auth.accessToken, let exp = JWT.expiry(token), exp > Date().addingTimeInterval(60) { return token }
        let token = try await generate(auth)
        try Task.checkCancellation()
        var renewed = auth
        renewed.accessToken = token
        try store.save(renewed)
        auth = renewed
        return token
    }
    private static func generateAccessToken(_ auth: StoredAuth) async throws -> String {
        var req = CAuthentication_AccessToken_GenerateForApp_Request()
        req.refreshToken = auth.refreshToken
        req.steamid = auth.steamID
        req.renewalType = .kEtokenRenewalTypeNone
        let (resp, result) = try await SteamWebAPI.callProto(
            interface: "IAuthenticationService", method: "GenerateAccessTokenForApp",
            request: req, responseType: CAuthentication_AccessToken_GenerateForApp_Response.self)
        guard result == .ok, !resp.accessToken.isEmpty else {
            throw SteamError.eresult(result, context: "GenerateAccessTokenForApp (refresh token may be expired — log in again)")
        }
        return resp.accessToken
    }
}
