import Foundation
import Domain

/// Mac games that are already on this Mac. Playden finds and launches them; it never installs,
/// changes or removes their files.
public struct LocalSource: GameSource {
    public let id = SourceID.local
    public let displayName = "This Mac"
    public var auth: any SourceAuth { NoSourceAuth() }
    public let capabilities = SourceCapabilities(account: .none, acquisition: .external)
    public let store: LocalLibraryStore
    private let suggestionRoots: [URL]

    public struct Candidate: Equatable, Sendable, Identifiable {
        public var id: URL { app.url }
        public let app: LocalAppBundle
        /// Already in the library; picking it again does nothing.
        public let added: Bool
        public init(app: LocalAppBundle, added: Bool) { self.app = app; self.added = added }
    }
    public struct FolderSummary: Equatable, Sendable, Identifiable {
        public var id: UUID { folder.id }
        public let folder: LocalLibrary.Folder
        public let gameCount: Int
        public let available: Bool
        public init(folder: LocalLibrary.Folder, gameCount: Int, available: Bool) {
            self.folder = folder; self.gameCount = gameCount; self.available = available
        }
    }

    public struct RemovedGame: Equatable, Sendable, Identifiable {
        public let id: GameID
        public let title: String
        public let lastKnownPath: URL
        /// The app is still where it was, or in a watched folder, so it can be restored as is.
        public let found: Bool
        public init(id: GameID, title: String, lastKnownPath: URL, found: Bool) {
            self.id = id; self.title = title; self.lastKnownPath = lastKnownPath; self.found = found
        }
    }

    public init(store: LocalLibraryStore, suggestionRoots: [URL] = LocalSource.standardSuggestionRoots) {
        self.store = store; self.suggestionRoots = suggestionRoots
    }
    public static var standardSuggestionRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"), home.appendingPathComponent("Games")]
    }

    // MARK: GameSource

    public func ownedGames() async throws -> [SourceGameRecord] {
        let library = try await scan()
        return library.entries.map { entry in
            let bundle = Self.resolve(entry).url.flatMap(LocalAppBundle.init(url:))
            var record = SourceGameRecord(id: gameID(entry), title: bundle?.title ?? entry.title ?? entry.lastKnownPath.deletingPathExtension().lastPathComponent,
                                          metadataUpdatedAt: .now, sourceAcquiredAt: entry.addedAt)
            record.platforms = [.macOS]
            return record
        }
    }
    public func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    public func installer(for game: SourceGameRecord) throws -> any Installer {
        throw OperationFailure(stage: "Install", reason: "This game is already on your Mac.", output: "")
    }
    public func externalInstallations(for games: [SourceGameRecord]) async throws -> [InstallationRecord] {
        let library = try await store.load()
        let records = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
        return library.entries.compactMap { entry in
            guard let game = records[gameID(entry)] else { return nil }
            let resolved = Self.resolve(entry)
            let app = resolved.url ?? entry.lastKnownPath
            var installation = InstallationRecord(game: game,
                location: GameLocation(volumeID: entry.volumeUUID ?? "", lastKnownRoot: app.deletingLastPathComponent(), relativePath: app.lastPathComponent),
                bottleID: "", manifestIDs: [:], templateVersion: "", launchSpec: LaunchSpec(executableRelativePath: app.lastPathComponent),
                installedAt: entry.addedAt, installedBytes: 0)
            installation.runtime = .native
            installation.external = ExternalLocation(bookmark: entry.bookmark, lastKnownPath: app, bundleIdentifier: entry.bundleIdentifier,
                executableName: entry.executableName, availability: resolved.availability, usesSteam: entry.usesSteam)
            return installation
        }
    }
    public func locate(_ installation: InstallationRecord) async throws -> URL {
        guard let entry = try await store.load().entries.first(where: { gameID($0) == installation.gameID }) else { throw ExternalLocationFailure.missing }
        let resolved = Self.resolve(entry)
        switch resolved.availability {
        case .available: return resolved.url!
        case .volumeUnavailable: throw ExternalLocationFailure.volumeUnavailable
        case .missing: throw ExternalLocationFailure.missing
        }
    }

    // MARK: Library management

    /// Apps in the standard folders that look like games, plus whether each is already added.
    public func suggestions() async throws -> [Candidate] {
        let library = try await store.load()
        var seen = Set<String>()
        return suggestionRoots.flatMap { LocalAppBundle.apps(in: $0, depth: 2) }.compactMap { url -> Candidate? in
            guard seen.insert(Self.realPath(url)).inserted, let app = LocalAppBundle(url: url), app.looksLikeGame else { return nil }
            return Candidate(app: app, added: Self.entryIndex(for: app, in: library) != nil)
        }.sorted { $0.app.title.localizedStandardCompare($1.app.title) == .orderedAscending }
    }
    /// Adds one app. A previously removed app gets its old identity back, so its history returns.
    @discardableResult public func add(_ url: URL, origin: LocalLibrary.Entry.Origin = .manual) async throws -> GameID {
        guard let app = LocalAppBundle(url: url) else {
            throw OperationFailure(stage: "Add game", reason: "That isn’t a Mac app Playden can open.", output: url.path)
        }
        return try await store.update { library in
            if let index = Self.entryIndex(for: app, in: library) { return gameID(library.entries[index]) }
            let entry = Self.entry(for: app, origin: Self.watchedFolder(containing: app.url, in: library).map { .folder($0) } ?? origin,
                                   reusing: Self.removedIndex(for: app, in: library).map { library.removed.remove(at: $0).id })
            library.entries.append(entry)
            return gameID(entry)
        }
    }
    /// Removes the game from the library. Folders skip it from now on; its playtime is kept.
    public func remove(_ id: GameID) async throws {
        try await store.update { library in
            guard let index = library.entries.firstIndex(where: { gameID($0) == id }) else { return }
            let entry = library.entries.remove(at: index)
            library.removed.removeAll { $0.id == entry.id }
            let folderID: UUID? = if case .folder(let folder) = entry.origin { folder } else { nil }
            library.removed.append(.init(id: entry.id, lastKnownPath: Self.resolve(entry).url ?? entry.lastKnownPath,
                                         bundleIdentifier: entry.bundleIdentifier, executableName: entry.executableName, removedAt: .now,
                                         title: entry.title, folderID: folderID))
        }
    }
    /// Games the player removed, most recent first.
    public func removedGames() async throws -> [RemovedGame] {
        let library = try await store.load()
        return library.removed.sorted { $0.removedAt > $1.removedAt }.map { removed in
            RemovedGame(id: GameID(source: id, value: removed.id),
                        title: removed.title ?? removed.lastKnownPath.deletingPathExtension().lastPathComponent,
                        lastKnownPath: removed.lastKnownPath, found: Self.locate(removed, in: library) != nil)
        }
    }
    /// Puts a removed game back with its identity and playtime. A game from a watched folder
    /// becomes a folder game again; one that moved is looked for in the watched folders.
    @discardableResult public func restore(_ id: GameID) async throws -> GameID {
        try await store.update { library in
            guard let index = library.removed.firstIndex(where: { GameID(source: self.id, value: $0.id) == id }) else { throw ExternalLocationFailure.missing }
            let removed = library.removed[index]
            guard let app = Self.locate(removed, in: library) else {
                throw OperationFailure(stage: "Restore game", reason: "Playden can’t find this app anymore. Choose an app to add it from its new place.",
                                       output: removed.lastKnownPath.path)
            }
            library.removed.remove(at: index)
            if let existing = Self.entryIndex(for: app, in: library) { return gameID(library.entries[existing]) }
            let folder = Self.watchedFolder(containing: app.url, in: library)
                ?? removed.folderID.flatMap { folderID in library.folders.contains { $0.id == folderID } ? folderID : nil }
            let entry = Self.entry(for: app, origin: folder.map { .folder($0) } ?? .manual, reusing: removed.id)
            library.entries.append(entry)
            return gameID(entry)
        }
    }
    /// Points a missing game at the app's new location, keeping its identity.
    public func relocate(_ id: GameID, to url: URL) async throws {
        guard let app = LocalAppBundle(url: url) else {
            throw OperationFailure(stage: "Locate game", reason: "That isn’t a Mac app Playden can open.", output: url.path)
        }
        try await store.update { library in
            guard let index = library.entries.firstIndex(where: { gameID($0) == id }) else { throw ExternalLocationFailure.missing }
            if let other = Self.entryIndex(for: app, in: library), other != index {
                throw OperationFailure(stage: "Locate game", reason: "That app is already in your library.", output: url.path)
            }
            var updated = Self.entry(for: app, origin: library.entries[index].origin, reusing: library.entries[index].id)
            updated.addedAt = library.entries[index].addedAt
            library.entries[index] = updated
        }
    }
    public func addFolder(_ url: URL) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue, url.pathExtension.lowercased() != "app" else {
            throw OperationFailure(stage: "Add folder", reason: "Choose a folder that contains games.", output: url.path)
        }
        try await store.update { library in
            guard !library.folders.contains(where: { Self.realPath($0.lastKnownPath) == Self.realPath(url) }) else { return }
            library.folders.append(.init(bookmark: Self.bookmark(url), lastKnownPath: url))
        }
    }
    /// Keeping the games turns them into manual entries; otherwise they leave the library.
    public func removeFolder(_ id: UUID, removingGames: Bool) async throws {
        let games = try await store.load().entries.filter { $0.origin == .folder(id) }.map(gameID)
        if removingGames { for game in games { try await remove(game) } }
        try await store.update { library in
            library.folders.removeAll { $0.id == id }
            for index in library.entries.indices where library.entries[index].origin == .folder(id) { library.entries[index].origin = .manual }
        }
    }
    public func folders() async throws -> [FolderSummary] {
        let library = try await store.load()
        return library.folders.map { folder in
            FolderSummary(folder: folder, gameCount: library.entries.filter { $0.origin == .folder(folder.id) }.count,
                          available: Self.resolveFolder(folder) != nil)
        }
    }
    public func reset() async throws { try await store.reset() }

    // MARK: Scanning

    /// Adds new apps from watched folders and refreshes where each known app is now.
    func scan() async throws -> LocalLibrary {
        try await store.update { library in
            for folder in library.folders {
                guard let root = Self.resolveFolder(folder) else { continue }
                for url in LocalAppBundle.apps(in: root, depth: folder.depth) {
                    guard let app = LocalAppBundle(url: url), Self.entryIndex(for: app, in: library) == nil,
                          Self.removedIndex(for: app, in: library) == nil else { continue }
                    library.entries.append(Self.entry(for: app, origin: .folder(folder.id), reusing: nil))
                }
            }
            for index in library.entries.indices {
                let entry = library.entries[index]
                guard let url = Self.resolve(entry).url else { continue }
                // Follow moves and renames; the identity and date added stay the same.
                if Self.realPath(url) != Self.realPath(entry.lastKnownPath) || entry.bookmark == nil {
                    library.entries[index].lastKnownPath = url
                    library.entries[index].bookmark = Self.bookmark(url) ?? entry.bookmark
                    library.entries[index].volumeUUID = Self.volumeUUID(url) ?? entry.volumeUUID
                }
                if let app = LocalAppBundle(url: url) {
                    library.entries[index].title = app.title
                    library.entries[index].usesSteam = app.usesSteam
                    library.entries[index].bundleIdentifier = app.bundleIdentifier
                    library.entries[index].executableName = app.executableName
                }
            }
            return library
        }
    }

    // MARK: Identity and resolution

    private func gameID(_ entry: LocalLibrary.Entry) -> GameID { GameID(source: id, value: entry.id) }

    /// Same place first; otherwise the same bundle identifier and executable. A bundle identifier
    /// alone is not enough, because many engine builds ship a default one.
    static func matches(path: URL, bundleIdentifier: String?, executableName: String?, _ app: LocalAppBundle) -> Bool {
        if realPath(path) == realPath(app.url) { return true }
        guard let bundleIdentifier, let executableName, let otherID = app.bundleIdentifier, let otherExecutable = app.executableName else { return false }
        return bundleIdentifier == otherID && executableName == otherExecutable
    }
    static func entryIndex(for app: LocalAppBundle, in library: LocalLibrary) -> Int? {
        library.entries.firstIndex { entry in
            matches(path: resolve(entry).url ?? entry.lastKnownPath, bundleIdentifier: entry.bundleIdentifier, executableName: entry.executableName, app)
        }
    }
    /// Where a removed app is now: its last place, else the watched folders.
    static func locate(_ removed: LocalLibrary.Removed, in library: LocalLibrary) -> LocalAppBundle? {
        if let app = LocalAppBundle(url: removed.lastKnownPath),
           matches(path: removed.lastKnownPath, bundleIdentifier: removed.bundleIdentifier, executableName: removed.executableName, app) { return app }
        for folder in library.folders {
            guard let root = resolveFolder(folder) else { continue }
            for url in LocalAppBundle.apps(in: root, depth: folder.depth) {
                if let app = LocalAppBundle(url: url),
                   matches(path: removed.lastKnownPath, bundleIdentifier: removed.bundleIdentifier, executableName: removed.executableName, app) { return app }
            }
        }
        return nil
    }
    /// The watched folder an app sits in, within that folder's scan depth.
    static func watchedFolder(containing app: URL, in library: LocalLibrary) -> UUID? {
        let path = realPath(app)
        return library.folders.first { folder in
            guard let root = resolveFolder(folder) else { return false }
            let rootPath = realPath(root)
            guard path.hasPrefix(rootPath + "/") else { return false }
            let levels = path.dropFirst(rootPath.count + 1).split(separator: "/").count
            return levels <= folder.depth
        }?.id
    }
    static func removedIndex(for app: LocalAppBundle, in library: LocalLibrary) -> Int? {
        library.removed.firstIndex { matches(path: $0.lastKnownPath, bundleIdentifier: $0.bundleIdentifier, executableName: $0.executableName, app) }
    }
    static func entry(for app: LocalAppBundle, origin: LocalLibrary.Entry.Origin, reusing id: String?) -> LocalLibrary.Entry {
        var entry = LocalLibrary.Entry(bookmark: bookmark(app.url), lastKnownPath: app.url, volumeUUID: volumeUUID(app.url),
                                       bundleIdentifier: app.bundleIdentifier, executableName: app.executableName, origin: origin, usesSteam: app.usesSteam)
        if let id { entry.id = id }
        entry.title = app.title
        return entry
    }
    static func resolve(_ entry: LocalLibrary.Entry) -> (url: URL?, availability: ExternalLocation.Availability) {
        if let bookmark = entry.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               isApp(url) { return (url, .available) }
        }
        if isApp(entry.lastKnownPath) { return (entry.lastKnownPath, .available) }
        return (nil, volumeMounted(uuid: entry.volumeUUID, path: entry.lastKnownPath) ? .missing : .volumeUnavailable)
    }
    static func resolveFolder(_ folder: LocalLibrary.Folder) -> URL? {
        var stale = false
        if let bookmark = folder.bookmark,
           let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
           FileManager.default.fileExists(atPath: url.path) { return url }
        return FileManager.default.fileExists(atPath: folder.lastKnownPath.path) ? folder.lastKnownPath : nil
    }
    private static func isApp(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
    }
    private static func bookmark(_ url: URL) -> Data? { try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
    private static func volumeUUID(_ url: URL) -> String? { try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString }
    /// An app on an unmounted drive is disconnected, not missing.
    private static func volumeMounted(uuid: String?, path: URL) -> Bool {
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: [.skipHiddenVolumes]) ?? []
        if let uuid { return mounted.contains { (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == uuid } }
        let parts = path.standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
    }
    static func realPath(_ url: URL) -> String {
        guard let real = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(real) }
        return String(cString: real)
    }
}
