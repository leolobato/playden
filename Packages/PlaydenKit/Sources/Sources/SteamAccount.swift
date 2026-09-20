import Foundation
import CryptoKit
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
    func downloadSizeAccountKey() throws -> String? {
        guard let auth = try store.load() else { return nil }
        return SHA256.hash(data: Data("steam-download-size:\(auth.steamID)".utf8)).map { String(format: "%02x", $0) }.joined()
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
        var transientFailures = 0
        while true {
            do {
                let credentials = try await backend.loginQR(onEvent: onEvent)
                try validate(attempt)
                try save(credentials)
                return Self.identity(credentials)
            } catch {
                try validate(attempt)
                let failure = sourceFailure(error)
                if failure == .expired {
                    transientFailures = 0
                    onEvent(.expired)
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                if [.network, .unavailable].contains(failure), transientFailures < 2 {
                    transientFailures += 1
                    try await Task.sleep(for: .milliseconds(Int64(transientFailures * 500)))
                    continue
                }
                throw failure
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
    func authenticatedOperation<T: Sendable>(diagnostic: @escaping @Sendable (String) -> Void = { _ in }, _ operation: @escaping @Sendable (StoredAuth) async throws -> T) async throws -> T {
        let attempt = generation
        do {
            guard let saved = try store.load() else { throw SourceFailure.signedOut }
            let id = UUID()
            let task = Task {
                diagnostic("renew start")
                let credentials: StoredAuth
                do { credentials = try await backend.renew(saved) }
                catch { diagnostic("renew failed: \(SteamConnectionDiagnostics.summary(error))"); throw error }
                try validate(attempt); try save(credentials)
                diagnostic("renew complete")
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
    func withCM<T: Sendable>(purpose: String = "operation", appID: UInt32? = nil, _ operation: @escaping @Sendable (CMClient) async throws -> T) async throws -> T {
        let id = UUID()
        let report: @Sendable (String) -> Void = { message in
            SteamConnectionDiagnostics.shared.record("\(id) \(purpose) app=\(appID.map(String.init) ?? "none") \(message)")
        }
        report("start active=\(operations.count)")
        defer { report("end") }
        return try await authenticatedOperation(diagnostic: report) { credentials in
            let cm = CMClient(depotKeyStore: MemoryDepotKeys(), diagnostic: report)
            var stage = "connect"
            do {
                try await cm.connect()
                report("connected")
                stage = "logon"
                _ = try await cm.logOn(accountName: credentials.accountName, refreshToken: credentials.refreshToken)
                stage = "licenses"
                try await cm.waitForLicenses()
                stage = "content"
                report("content start")
                let result = try await operation(cm)
                report("content complete")
                await cm.disconnect()
                return result
            } catch {
                report("\(stage) failed: \(SteamConnectionDiagnostics.summary(error))")
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
