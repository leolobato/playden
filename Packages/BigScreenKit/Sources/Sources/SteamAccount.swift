import Foundation
import Domain
import SteamCore

public actor SteamAccount: SourceAuth {
    private let store: any AuthCredentialStore
    private let backend: any SteamBackend
    private var generation = 0
    public init() { store = KeychainCredentials(); backend = LiveSteamBackend() }
    init(store: any AuthCredentialStore, backend: any SteamBackend) { self.store = store; self.backend = backend }
    public func identity() async throws -> SourceIdentity? {
        do { return try store.load().map(Self.identity) } catch { throw SourceFailure.storage("Keychain") }
    }
    public func cancelSignIn() { generation += 1 }
    public func signOut() throws {
        generation += 1
        do { try store.clear() } catch { throw SourceFailure.storage("Keychain") }
    }
    public func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity {
        generation += 1; let attempt = generation
        while true {
            do {
                let credentials = try await backend.loginQR(onEvent: onEvent)
                try validate(attempt)
                try save(credentials)
                return Self.identity(credentials)
            } catch {
                try validate(attempt)
                if sourceFailure(error) == .expired {
                    onEvent(.expired)
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                throw sourceFailure(error)
            }
        }
    }
    public func signIn(accountName: String, password: String,
                       codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                       onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity {
        generation += 1; let attempt = generation
        do {
            let saved = try store.load()
            let guardData = saved?.accountName == accountName ? saved?.guardData : nil
            let credentials = try await backend.login(accountName: accountName, password: password, guardData: guardData,
                codeProvider: codeProvider, onEvent: onEvent)
            try validate(attempt); try save(credentials)
            return Self.identity(credentials)
        } catch { throw sourceFailure(error) }
    }
    func ownedGames() async throws -> [SourceGameRecord] {
        let attempt = generation
        do {
            guard let saved = try store.load() else { throw SourceFailure.signedOut }
            let credentials = try await backend.renew(saved)
            try validate(attempt); try save(credentials)
            let games = try await backend.ownedGames(credentials)
            try validate(attempt)
            return games
        } catch { throw sourceFailure(error) }
    }
    private func validate(_ attempt: Int) throws {
        try Task.checkCancellation()
        guard generation == attempt else { throw SourceFailure.cancelled }
    }
    private func save(_ credentials: StoredAuth) throws {
        do { try store.save(credentials) } catch { throw SourceFailure.storage("Keychain") }
    }
    private static func identity(_ credentials: StoredAuth) -> SourceIdentity {
        SourceIdentity(sourceID: "steam", displayName: credentials.accountName)
    }
}
