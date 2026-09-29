import Foundation
import Domain
import GOGCore

/// Where the Galaxy session lives between runs. Only the Keychain in the app; memory in tests.
public protocol GOGCredentialStore: Sendable {
    func load() throws -> GOGSession?
    func save(_ session: GOGSession) throws
    func clear() throws
}
struct KeychainGOGCredentials: GOGCredentialStore {
    let item = KeychainItem<GOGSession>(service: KeychainItem<GOGSession>.service("gog"))
    func load() throws -> GOGSession? { try item.load() }
    func save(_ session: GOGSession) throws { try item.save(session) }
    func clear() throws { try item.clear() }
}
public final class MemoryGOGCredentials: GOGCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: GOGSession?
    public init(_ value: GOGSession? = nil) { self.value = value }
    public func load() throws -> GOGSession? { lock.withLock { value } }
    public func save(_ session: GOGSession) throws { lock.withLock { value = session } }
    public func clear() throws { lock.withLock { value = nil } }
}

/// The GOG account: web-login sign-in, the saved Galaxy session, and a fresh access token for each call
/// (PRD 10 §2).
public actor GOGAccount: SourceAuth {
    let auth: GOGAuth
    let api: GOGAPI
    private let store: any GOGCredentialStore
    private var cached: GOGSession?
    /// Bumped on sign-out, so a refresh that was in flight can't save a session back.
    private var generation = 0

    public init(store: any GOGCredentialStore, auth: GOGAuth = GOGAuth(), api: GOGAPI = GOGAPI()) {
        self.store = store; self.auth = auth; self.api = api
    }
    public init() { self.init(store: KeychainGOGCredentials()) }

    public func identity() async throws -> SourceIdentity? {
        guard let session = try loadSession() else { return nil }
        return SourceIdentity(sourceID: SourceID.gog, displayName: session.displayName ?? "GOG")
    }

    public func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity {
        throw SourceFailure.unavailable
    }
    public func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                       onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity {
        throw SourceFailure.unavailable
    }

    public nonisolated func webLoginURL() -> URL? { auth.loginURL() }

    /// The page every Galaxy login ends on.
    public nonisolated func redirectMatches(_ url: URL) -> Bool {
        url.host?.lowercased() == "embed.gog.com" && url.path == "/on_login_success"
    }

    /// Finishes a sign-in with the address the login ended on, or the code alone (FR-GOG-3).
    public func signIn(withRedirect pasted: String) async throws -> SourceIdentity {
        let code: String
        do { code = try GOGAuth.code(from: pasted) } catch { throw SourceFailure.credentialsRejected }
        do {
            var session = try await auth.exchange(code: code)
            session.displayName = try? await api.displayName(accessToken: session.accessToken)
            generation += 1
            try save(session)
            return SourceIdentity(sourceID: SourceID.gog, displayName: session.displayName ?? "GOG")
        } catch GOGError.invalidCredentials {
            throw SourceFailure.credentialsRejected
        } catch { throw Self.failure(error) }
    }

    public func cancelSignIn() async {}

    /// GOG has no session to end; forgetting it on this Mac is the sign-out (FR-GOG-6).
    public func signOut() async throws {
        generation += 1
        cached = nil
        do { try store.clear() } catch { throw SourceFailure.storage(String(describing: error)) }
    }

    /// Runs `operation` with a session good for at least ten minutes, refreshing and saving it first if needed.
    public func withSession<T: Sendable>(_ operation: @Sendable (GOGSession) async throws -> T) async throws -> T {
        do {
            return try await operation(try await validSession())
        } catch { throw Self.failure(error) }
    }

    /// A current access token, for downloads that outlive one token.
    public func accessToken() async throws -> String {
        do { return try await validSession().accessToken } catch { throw Self.failure(error) }
    }

    private func validSession() async throws -> GOGSession {
        guard let stored = try loadSession() else { throw SourceFailure.signedOut }
        guard stored.needsRefresh() else { return stored }
        let started = generation
        let session: GOGSession
        do { session = try await auth.refresh(stored) }
        catch GOGError.invalidCredentials {
            if generation == started { cached = nil; try? store.clear() }
            throw SourceFailure.expired
        }
        guard generation == started else { throw SourceFailure.signedOut }
        try save(session)
        return session
    }

    private func loadSession() throws -> GOGSession? {
        if let cached { return cached }
        do { cached = try store.load() } catch { throw SourceFailure.storage(String(describing: error)) }
        return cached
    }
    private func save(_ session: GOGSession) throws {
        do { try store.save(session) } catch { throw SourceFailure.storage(String(describing: error)) }
        cached = session
    }

    /// Maps GOG's errors onto the failures the app knows how to present.
    static func failure(_ error: Error) -> Error {
        switch error {
        case let failure as SourceFailure: return failure
        case let failure as OperationFailure: return failure
        case is CancellationError: return error
        case let gog as GOGError:
            switch gog {
            case .network: return SourceFailure.network
            case .cancelled: return CancellationError()
            case .invalidCredentials: return SourceFailure.expired
            case .malformed, .noCode: return SourceFailure.malformedResponse
            case .unauthorized: return SourceFailure.accessDenied
            case .noBuild: return OperationFailure(stage: "Resolve", reason: gog.localizedDescription, output: "")
            case .hashMismatch: return OperationFailure(stage: "Download", reason: "A downloaded file didn't match GOG's checksum. Retry the download.", output: gog.localizedDescription)
            case .http(let status, _, _):
                switch status {
                case 401: return SourceFailure.expired
                case 403, 404: return SourceFailure.accessDenied
                case 429: return SourceFailure.throttled
                default: return SourceFailure.unavailable
                }
            }
        default: return error
        }
    }
}

/// GOG: DRM-free Windows and Mac builds from the Galaxy content system (PRD 10).
public struct GOGSource: GameSource {
    public let id = SourceID.gog
    public let displayName = "GOG"
    public var auth: any SourceAuth { account }
    public let capabilities = SourceCapabilities(account: .webLogin, acquisition: .download)
    public let account: GOGAccount
    private let catalog: GOGCatalogCache

    public init(account: GOGAccount = GOGAccount(), cacheDirectory: URL? = nil) {
        self.account = account
        catalog = GOGCatalogCache(file: cacheDirectory?.appendingPathComponent("gog-catalog.json"))
    }

    public func ownedGames() async throws -> [SourceGameRecord] {
        let catalog = self.catalog
        return try await account.withSession { [api = account.api] session in
            let owned = try await api.ownedProductIDs(accessToken: session.accessToken).map(String.init)
            let entries = try await catalog.entries(for: owned, api: api)
            return owned.compactMap { id -> SourceGameRecord? in
                guard let entry = entries[id], entry.isListedGame else { return nil }
                let record = Self.record(entry)
                return record.platforms?.isEmpty == false ? record : nil
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    public func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord {
        // `ownedGames` already carries the gamesdb metadata; nothing more to fetch.
        var result = game
        result.metadataUpdatedAt = .now
        return result
    }

    public func installer(for game: SourceGameRecord) throws -> any Installer {
        guard game.id.source == id, Int(game.id.value) != nil else { throw SourceFailure.malformedResponse }
        return GOGInstaller(game: game, account: account)
    }

    public func storePageURL(for id: GameID) -> URL? { nil }

    /// Linux-only games have no build Playden can run, so they get no platforms and no tile.
    static func record(_ entry: GOGGameEntry) -> SourceGameRecord {
        var record = SourceGameRecord(id: GameID(source: SourceID.gog, value: entry.productID), title: entry.title,
                                      summary: entry.summary ?? "", genres: entry.genres, coverURL: entry.cover, heroURL: entry.hero,
                                      logoURL: entry.logo, metadataUpdatedAt: .now)
        record.platforms = [(GamePlatform.windows, "windows"), (.macOS, "osx")].filter { entry.systems.contains($0.1) }.map(\.0)
        return record
    }
}

/// gamesdb entries by product ID with their ETags, kept on disk between launches (FR-GOG-11).
actor GOGCatalogCache {
    private struct Entry: Codable { var etag: String?; var entry: GOGGameEntry?; var logoChecked: Bool? }
    private let file: URL?
    private var entries: [String: Entry]?

    init(file: URL?) { self.file = file }

    func entries(for products: [String], api: GOGAPI) async throws -> [String: GOGGameEntry] {
        var entries = loaded()
        var changed = false
        try await withThrowingTaskGroup(of: (String, Entry?).self) { group in
            var iterator = products.makeIterator()
            let known = entries
            func add(_ id: String) {
                group.addTask {
                    let previous = known[id]
                    switch try await api.gamesDBEntry(productID: id, etag: previous?.entry == nil ? nil : previous?.etag) {
                    case .notModified:
                        guard var entry = previous, entry.logoChecked != true, var game = entry.entry, game.isListedGame else { return (id, nil) }
                        game.logo = try? await api.logo(productID: id)
                        entry.entry = game; entry.logoChecked = true
                        return (id, entry)
                    case .missing: return (id, Entry(etag: nil, entry: nil))
                    case .entry(var game, let etag):
                        if game.isListedGame { game.logo = try? await api.logo(productID: id) }
                        return (id, Entry(etag: etag, entry: game, logoChecked: true))
                    }
                }
            }
            for _ in 0..<8 { if let next = iterator.next() { add(next) } }
            while let (id, entry) = try await group.next() {
                if let entry { entries[id] = entry; changed = true }
                if let next = iterator.next() { add(next) }
            }
        }
        self.entries = entries
        if changed, let file, let data = try? JSONEncoder().encode(entries) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return entries.compactMapValues(\.entry)
    }

    private func loaded() -> [String: Entry] {
        if let entries { return entries }
        let decoded = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = decoded
        return decoded
    }
}
