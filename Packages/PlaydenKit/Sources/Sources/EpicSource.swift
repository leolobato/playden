import Foundation
import Domain
import EpicCore

/// Where the launcher session lives between runs. Only the Keychain in the app; memory in tests.
public protocol EpicCredentialStore: Sendable {
    func load() throws -> EpicSession?
    func save(_ session: EpicSession) throws
    func clear() throws
}
struct KeychainEpicCredentials: EpicCredentialStore {
    let item = KeychainItem<EpicSession>(service: KeychainItem<EpicSession>.service("epic"))
    func load() throws -> EpicSession? { try item.load() }
    func save(_ session: EpicSession) throws { try item.save(session) }
    func clear() throws { try item.clear() }
}
public final class MemoryEpicCredentials: EpicCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: EpicSession?
    public init(_ value: EpicSession? = nil) { self.value = value }
    public func load() throws -> EpicSession? { lock.withLock { value } }
    public func save(_ session: EpicSession) throws { lock.withLock { value = session } }
    public func clear() throws { lock.withLock { value = nil } }
}

/// The Epic account: device-code sign-in, the saved launcher session, and a fresh access token for each call.
public actor EpicAccount: SourceAuth {
    let auth: EpicAuth
    let api: EpicLibraryAPI
    private let store: any EpicCredentialStore
    private var cached: EpicSession?
    private var signInTask: Task<EpicSession, Error>?
    /// Bumped on sign-out, so a refresh that was in flight can't save a session back.
    private var generation = 0

    public init(store: any EpicCredentialStore, auth: EpicAuth = EpicAuth(), api: EpicLibraryAPI = EpicLibraryAPI()) {
        self.store = store; self.auth = auth; self.api = api
    }
    public init() { self.init(store: KeychainEpicCredentials()) }

    public func identity() async throws -> SourceIdentity? {
        guard let session = try loadSession() else { return nil }
        return SourceIdentity(sourceID: SourceID.epic, displayName: session.displayName)
    }

    public func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity {
        try await signInWithDeviceCode(onEvent: onEvent)
    }
    public func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                       onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity {
        throw SourceFailure.unavailable
    }

    /// Shows a code until the player approves it; an expired code is replaced with a new one.
    public func signInWithDeviceCode(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity {
        signInTask?.cancel()
        let auth = self.auth
        let task = Task<EpicSession, Error> {
            while true {
                try Task.checkCancellation()
                let authorization = try await auth.startDeviceAuthorization()
                onEvent(.deviceCode(userCode: authorization.userCode, verificationURL: authorization.verificationURL,
                                    completeURL: authorization.completeVerificationURL, expiresAt: authorization.expiresAt))
                do { return try await auth.completeDeviceAuthorization(authorization) }
                catch EpicError.deviceCodeExpired { onEvent(.expired) }
            }
        }
        signInTask = task
        do {
            let session = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try save(session)
            return SourceIdentity(sourceID: SourceID.epic, displayName: session.displayName)
        } catch { throw Self.failure(error) }
    }

    public func cancelSignIn() async { signInTask?.cancel(); signInTask = nil }

    /// Ends the session on Epic when it can; forgetting it on this Mac is what must succeed.
    public func signOut() async throws {
        generation += 1
        let session = cached ?? (try? store.load())
        cached = nil
        do { try store.clear() } catch { throw SourceFailure.storage(String(describing: error)) }
        if let session { try? await auth.killSession(accessToken: session.accessToken) }
    }

    /// Runs `operation` with a session good for at least ten minutes, refreshing and saving it first if needed.
    public func withSession<T: Sendable>(_ operation: @Sendable (EpicSession) async throws -> T) async throws -> T {
        do {
            guard let stored = try loadSession() else { throw SourceFailure.signedOut }
            let started = generation
            var session = stored
            if session.needsRefresh() {
                do { session = try await auth.refresh(stored) }
                catch EpicError.invalidCredentials {
                    if generation == started { cached = nil; try? store.clear() }
                    throw SourceFailure.expired
                }
                guard generation == started else { throw SourceFailure.signedOut }
                try save(session)
            }
            return try await operation(session)
        } catch { throw Self.failure(error) }
    }

    private func loadSession() throws -> EpicSession? {
        if let cached { return cached }
        do { cached = try store.load() } catch { throw SourceFailure.storage(String(describing: error)) }
        return cached
    }
    private func save(_ session: EpicSession) throws {
        do { try store.save(session) } catch { throw SourceFailure.storage(String(describing: error)) }
        cached = session
    }

    /// Maps Epic's errors onto the failures the app knows how to present.
    static func failure(_ error: Error) -> Error {
        switch error {
        case let failure as SourceFailure: return failure
        case is CancellationError: return error
        case let epic as EpicError:
            switch epic {
            case .network: return SourceFailure.network
            case .cancelled: return CancellationError()
            case .invalidCredentials, .deviceCodeExpired: return SourceFailure.expired
            case .malformed: return SourceFailure.malformedResponse
            case .correctiveAction(let url): return SourceFailure.actionRequired(url)
            case .http(let status, _, _):
                switch status {
                case 401: return SourceFailure.expired
                case 403, 404: return SourceFailure.accessDenied
                case 429: return SourceFailure.throttled
                default: return SourceFailure.unavailable
                }
            default: return epic
            }
        default: return error
        }
    }
}

/// Epic Games Store: Windows builds downloaded from Epic's CDN and run in CrossOver (PRD 09).
public struct EpicSource: GameSource {
    public let id = SourceID.epic
    public let displayName = "Epic Games"
    public var auth: any SourceAuth { account }
    public let capabilities = SourceCapabilities(account: .deviceCode, acquisition: .download)
    public let account: EpicAccount
    private let catalog: EpicCatalogCache

    public init(account: EpicAccount = EpicAccount(), cacheDirectory: URL? = nil) {
        self.account = account
        catalog = EpicCatalogCache(file: cacheDirectory?.appendingPathComponent("epic-catalog.json"))
    }

    public func ownedGames() async throws -> [SourceGameRecord] {
        let catalog = self.catalog
        return try await account.withSession { [api = account.api] session in
            async let assetsRequest = api.assets(platform: .windows, accessToken: session.accessToken)
            async let libraryRequest = api.libraryItems(accessToken: session.accessToken)
            let assets = try await assetsRequest
            // Acquisition dates are a nicety; the library service being down must not hide the games.
            let library = (try? await libraryRequest) ?? []
            var acquired: [String: Date] = [:]
            let dates = ISO8601DateFormatter(); dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for record in library { if let app = record.appName, let date = record.acquisitionDate.flatMap(dates.date(from:)) { acquired[app] = date } }

            var seen = Set<String>()
            let candidates = assets.filter { $0.namespace != "ue" && seen.insert($0.appName).inserted }
            let items = try await catalog.items(for: candidates) { asset in
                try await api.catalogItem(namespace: asset.namespace, catalogItemID: asset.catalogItemId, accessToken: session.accessToken)
            }
            return candidates.compactMap { asset -> SourceGameRecord? in
                guard let item = items[asset.catalogItemId], Self.isInstallableGame(item) else { return nil }
                var record = Self.record(for: asset, item: item)
                record.sourceAcquiredAt = acquired[asset.appName]
                return record
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    public func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord {
        // `ownedGames` already carries the catalog metadata; nothing more to fetch.
        var result = game
        result.metadataUpdatedAt = .now
        return result
    }

    public func installer(for game: SourceGameRecord) throws -> any Installer {
        guard game.id.source == id, !game.id.value.isEmpty else { throw SourceFailure.malformedResponse }
        return EpicInstaller(game: game, account: account)
    }

    /// DLC, mods, digital extras (artbooks, soundtracks) and titles that need the EA app or Ubisoft
    /// Connect are not offered (PRD 09 FR-EPIC-8, FR-EPIC-9).
    static func isInstallableGame(_ item: EpicCatalogItem) -> Bool {
        let categories = item.categoryPaths
        return !item.isDLC && !categories.contains("mods") && !categories.contains("digitalextras") && item.thirdPartyStore == nil
    }

    static func record(for asset: EpicAsset, item: EpicCatalogItem) -> SourceGameRecord {
        var record = SourceGameRecord(id: GameID(source: SourceID.epic, value: asset.appName), title: item.title,
                                      summary: item.description ?? "",
                                      coverURL: item.image(["DieselGameBoxTall", "OfferImageTall", "Thumbnail"]),
                                      heroURL: item.image(["DieselGameBox", "OfferImageWide", "DieselStoreFrontWide"]),
                                      logoURL: item.image(["DieselGameBoxLogo"]), metadataUpdatedAt: .now)
        record.platforms = [.windows]
        return record
    }
}

/// Catalog items by ID, kept on disk between launches. Items are fetched again when the asset's build changes.
actor EpicCatalogCache {
    private struct Entry: Codable { var buildVersion: String; var item: EpicCatalogItem }
    private let file: URL?
    private var entries: [String: Entry]?

    init(file: URL?) { self.file = file }

    func items(for assets: [EpicAsset], fetch: @escaping @Sendable (EpicAsset) async throws -> EpicCatalogItem?) async throws -> [String: EpicCatalogItem] {
        var entries = loaded()
        let missing = assets.filter { entries[$0.catalogItemId]?.buildVersion != $0.buildVersion }
        try await withThrowingTaskGroup(of: (EpicAsset, EpicCatalogItem?).self) { group in
            var iterator = missing.makeIterator()
            for _ in 0..<8 { if let next = iterator.next() { group.addTask { (next, try await fetch(next)) } } }
            while let (asset, item) = try await group.next() {
                if let item { entries[asset.catalogItemId] = Entry(buildVersion: asset.buildVersion, item: item) }
                if let next = iterator.next() { group.addTask { (next, try await fetch(next)) } }
            }
        }
        self.entries = entries
        if !missing.isEmpty, let file, let data = try? JSONEncoder().encode(entries) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return entries.mapValues(\.item)
    }

    private func loaded() -> [String: Entry] {
        if let entries { return entries }
        let decoded = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = decoded
        return decoded
    }
}
