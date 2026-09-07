import Foundation
import Domain
import SteamCore

protocol SteamBackend: Sendable {
    func loginQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> StoredAuth
    func login(accountName: String, password: String, guardData: String?,
               codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
               onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> StoredAuth
    func renew(_ auth: StoredAuth) async throws -> StoredAuth
    func ownedGames(_ auth: StoredAuth) async throws -> [SourceGameRecord]
}
struct LiveSteamBackend: SteamBackend {
    func loginQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> StoredAuth {
        try await SteamAuth.loginWithQR(deviceName: "Big Screen") { event in Self.deliver(event, to: onEvent) }
    }
    func login(accountName: String, password: String, guardData: String?,
               codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
               onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> StoredAuth {
        try await SteamAuth.loginWithPassword(accountName: accountName, password: password, guardData: guardData, deviceName: "Big Screen",
            codeProvider: { prompt in try await codeProvider({ switch prompt { case .deviceCode: .authenticator; case .emailCode: .email } }()) },
            onEvent: { Self.deliver($0, to: onEvent) })
    }
    func renew(_ auth: StoredAuth) async throws -> StoredAuth {
        var renewed = auth
        // Renewal is staged in memory. SteamAccount commits to Keychain only after checking that
        // sign-out/account replacement did not happen while this request was suspended.
        _ = try await SteamAuth.validAccessToken(&renewed, store: MemoryCredentials())
        return renewed
    }
    func ownedGames(_ auth: StoredAuth) async throws -> [SourceGameRecord] {
        guard let token = auth.accessToken else { throw SourceFailure.expired }
        return try await SteamLibrary.ownedGames(steamID: auth.steamID, accessToken: token).map { game in
            let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.appID)"
            return SourceGameRecord(id: GameID(source: "steam", value: String(game.appID)), title: game.name,
                coverURL: URL(string: "\(base)/library_600x900.jpg"), heroURL: URL(string: "\(base)/library_hero.jpg"),
                logoURL: URL(string: "\(base)/logo.png"), importedPlaytimeSeconds: Int64(game.playtimeMinutes) * 60,
                sourceLastPlayedAt: game.lastPlayedAt)
        }
    }
    private static func deliver(_ event: AuthEvent, to receiver: @Sendable (AuthenticationEvent) -> Void) {
        switch event {
        case .waitingForDeviceConfirmation: receiver(.awaitingApproval)
        case .qrChallenge(let challenge):
            if let url = URL(string: challenge), url.scheme == "https", url.host == "s.team" || url.host == "steamcommunity.com" {
                receiver(.qrChallenge(url, expiresAt: .now.addingTimeInterval(300)))
            }
        }
    }
}
func sourceFailure(_ error: Error) -> SourceFailure {
    if let failure = error as? SourceFailure { return failure }
    if error is CancellationError { return .cancelled }
    if let network = error as? URLError { return network.code == .cancelled ? .cancelled : .network }
    if error is KeychainFailure { return .storage("Keychain") }
    if let steam = error as? SteamError {
        switch steam {
        case .authSessionExpired: return .expired
        case .notLoggedIn: return .signedOut
        case .authFailed: return .credentialsRejected
        case .protocolError: return .malformedResponse
        case .http(let status, _): return status == 429 ? .throttled : [401, 403].contains(status) ? .expired : .unavailable
        case .eresult(let result, _):
            if [.expired, .accessDenied].contains(result) { return .expired }
            if [.invalidPassword, .invalidParam].contains(result) { return .credentialsRejected }
            if [.rateLimitExceeded, .accountLoginDeniedThrottle].contains(result) { return .throttled }
            return .unavailable
        default: return .unavailable
        }
    }
    return .unavailable
}
