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
        try await SteamAuth.loginWithQR(deviceName: "Playden") { event in Self.deliver(event, to: onEvent) }
    }
    func login(accountName: String, password: String, guardData: String?,
               codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
               onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> StoredAuth {
        try await SteamAuth.loginWithPassword(accountName: accountName, password: password, guardData: guardData, deviceName: "Playden",
            codeProvider: { prompt in try await codeProvider({ switch prompt { case .deviceCode: .authenticator; case .emailCode: .email } }()) },
            onEvent: { Self.deliver($0, to: onEvent) })
    }
    func renew(_ auth: StoredAuth) async throws -> StoredAuth {
        var renewed = auth
        // Renewal is staged in memory. SteamAccount commits to Keychain only after checking that
        // sign-out/account replacement did not happen while this request was suspended.
        do {
            _ = try await SteamAuth.validAccessToken(&renewed, store: MemoryCredentials())
        } catch {
            SteamConnectionDiagnostics.shared.record("token-renewal failed: \(SteamConnectionDiagnostics.summary(error))")
            // Only an authentication endpoint rejecting renewal implies an invalid session.
            // A content/depot AccessDenied response must not send users through sign-in again.
            if sourceFailure(error) == .accessDenied || sourceFailure(error) == .credentialsRejected { throw SourceFailure.expired }
            throw error
        }
        return renewed
    }
    func ownedGames(_ auth: StoredAuth) async throws -> [SourceGameRecord] {
        guard let token = auth.accessToken else { throw SourceFailure.expired }
        async let owned = SteamLibrary.ownedGames(steamID: auth.steamID, accessToken: token)
        async let acquired = acquisitionDates(auth)
        return try await Self.libraryRecords(owned, acquiredAt: acquired)
    }
    static func libraryRecords(_ games: [OwnedGame], acquiredAt: [UInt32: Date]) -> [SourceGameRecord] {
        games.map { game in
            let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.appID)"
            return SourceGameRecord(id: GameID(source: "steam", value: String(game.appID)), title: game.name,
                coverURL: URL(string: "\(base)/library_600x900.jpg"), heroURL: URL(string: "\(base)/library_hero.jpg"),
                logoURL: URL(string: "\(base)/logo.png"), importedPlaytimeSeconds: Int64(game.playtimeMinutes) * 60,
                sourceLastPlayedAt: game.lastPlayedAt, sourceAcquiredAt: acquiredAt[game.appID])
        }
    }
    private func acquisitionDates(_ auth: StoredAuth) async throws -> [UInt32: Date] {
        let id = UUID()
        let report: @Sendable (String) -> Void = { message in
            SteamConnectionDiagnostics.shared.record("\(id) library-entitlements \(message)")
        }
        report("start")
        defer { report("end") }
        let cm = CMClient(depotKeyStore: MemoryDepotKeys(), diagnostic: report)
        do {
            try await cm.connect()
            _ = try await cm.logOn(accountName: auth.accountName, refreshToken: auth.refreshToken)
            let result = try await cm.ownedEntitlements()
            await cm.disconnect()
            return result.appAcquiredAt
        } catch {
            report("failed: \(SteamConnectionDiagnostics.summary(error))")
            await cm.disconnect()
            try Task.checkCancellation()
            // Owned games still load if optional license metadata is temporarily unavailable.
            // CatalogStore retains previously known dates; unknown dates sort last.
            return [:]
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
    if error is KeychainFailure { return credentialFailure(error) }
    if let steam = error as? SteamError {
        switch steam {
        case .authSessionExpired: return .expired
        case .notLoggedIn: return .signedOut
        case .authFailed: return .credentialsRejected
        case .protocolError: return .malformedResponse
        case .http(let status, _): return status == 429 ? .throttled : status == 401 ? .expired : status == 403 ? .accessDenied : .unavailable
        case .eresult(let result, _):
            if result == .expired { return .expired }
            if result == .accessDenied { return .accessDenied }
            if [.invalidPassword, .invalidParam].contains(result) { return .credentialsRejected }
            if [.rateLimitExceeded, .accountLoginDeniedThrottle].contains(result) { return .throttled }
            return .unavailable
        default: return .unavailable
        }
    }
    return .unavailable
}
func credentialFailure(_ error: Error) -> SourceFailure {
    if let failure = error as? KeychainFailure { return .storage("macOS \(failure.status)") }
    return .storage("Keychain")
}
