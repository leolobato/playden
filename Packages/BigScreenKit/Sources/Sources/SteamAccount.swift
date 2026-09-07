import Foundation
import Domain
import SteamCore

public actor SteamAccount: SourceAuth {
    private let store: any AuthCredentialStore
    private let backend: any SteamBackend
    private var generation = 0
    private var operations: [UUID: @Sendable () -> Void] = [:]
    public init() { store = KeychainCredentials(); backend = LiveSteamBackend() }
    init(store: any AuthCredentialStore, backend: any SteamBackend) { self.store = store; self.backend = backend }
    public func identity() async throws -> SourceIdentity? {
        do { return try store.load().map(Self.identity) } catch { throw credentialFailure(error) }
    }
    private func invalidate() {
        generation += 1
        for cancel in operations.values { cancel() }
        operations.removeAll()
    }
    public func cancelSignIn() { invalidate() }
    public func signOut() throws {
        invalidate()
        do { try store.clear() } catch { throw credentialFailure(error) }
    }
    public func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity {
        invalidate(); let attempt = generation
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
        invalidate(); let attempt = generation
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
    /// Sources-only boundary: credentials never reach Catalog, Installs, Runner, or the UI.
    /// Replacing/signing out the account cancels active work as well as invalidating its result.
    func authenticatedOperation<T: Sendable>(_ operation: @escaping @Sendable (StoredAuth) async throws -> T) async throws -> T {
        let attempt = generation
        do {
            guard let saved = try store.load() else { throw SourceFailure.signedOut }
            let id = UUID()
            let task = Task {
                let credentials = try await backend.renew(saved)
                try validate(attempt); try save(credentials)
                return try await operation(credentials)
            }
            operations[id] = { task.cancel() }
            defer { operations[id] = nil }
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try validate(attempt)
            return result
        } catch let failure as OperationFailure { throw failure }
        catch { throw sourceFailure(error) }
    }
    func withCM<T: Sendable>(_ operation: @escaping @Sendable (CMClient) async throws -> T) async throws -> T {
        try await authenticatedOperation { credentials in
            let cm = CMClient(depotKeyStore: MemoryDepotKeys())
            do {
                try await cm.connect()
                _ = try await cm.logOn(accountName: credentials.accountName, refreshToken: credentials.refreshToken)
                try await cm.waitForLicenses()
                let result = try await operation(cm)
                await cm.disconnect()
                return result
            } catch {
                await cm.disconnect()
                if let steam = error as? SteamError, case .authFailed = steam { throw SourceFailure.expired }
                throw error
            }
        }
    }
    private func validate(_ attempt: Int) throws {
        try Task.checkCancellation()
        guard generation == attempt else { throw SourceFailure.cancelled }
    }
    private func save(_ credentials: StoredAuth) throws {
        do { try store.save(credentials) } catch { throw credentialFailure(error) }
    }
    private static func identity(_ credentials: StoredAuth) -> SourceIdentity {
        SourceIdentity(sourceID: "steam", displayName: credentials.accountName)
    }
}
