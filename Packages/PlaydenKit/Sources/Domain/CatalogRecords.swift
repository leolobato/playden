import Foundation

public enum ControllerSupport: String, Codable, CaseIterable, Sendable { case unknown, full, partial, none }

/// Source-owned metadata, never local edits or authentication/account identity.
public struct SourceGameRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: GameID
    public var title: String
    public var summary: String
    public var genres: [String]
    public var controllerSupport: ControllerSupport
    public var coverURL: URL?
    public var heroURL: URL?
    public var logoURL: URL?
    public var importedPlaytimeSeconds: Int64
    public var sourceLastPlayedAt: Date?
    /// When the source granted this game to the account, independent of our first sync.
    public var sourceAcquiredAt: Date?
    public var downloadBytes: Int64?
    public var firstObservedAt: Date
    public var metadataUpdatedAt: Date?

    public init(id: GameID, title: String, summary: String = "", genres: [String] = [],
                controllerSupport: ControllerSupport = .unknown, coverURL: URL? = nil, heroURL: URL? = nil,
                logoURL: URL? = nil, importedPlaytimeSeconds: Int64 = 0, sourceLastPlayedAt: Date? = nil,
                downloadBytes: Int64? = nil, firstObservedAt: Date = .now, metadataUpdatedAt: Date? = nil,
                sourceAcquiredAt: Date? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.genres = genres
        self.controllerSupport = controllerSupport; self.coverURL = coverURL; self.heroURL = heroURL; self.logoURL = logoURL
        self.importedPlaytimeSeconds = max(0, importedPlaytimeSeconds); self.sourceLastPlayedAt = sourceLastPlayedAt
        self.downloadBytes = downloadBytes; self.firstObservedAt = firstObservedAt; self.metadataUpdatedAt = metadataUpdatedAt
        self.sourceAcquiredAt = sourceAcquiredAt
    }
}

public enum ControllerMode: String, Codable, CaseIterable, Sendable {
    case xboxCompatible, native
    public static let playdenDefault: ControllerMode = .xboxCompatible
    public var title: String { self == .xboxCompatible ? "Xbox compatible" : "Native controller" }
}

public struct GameEdits: Codable, Equatable, Sendable {
    public var isFavorite: Bool
    public var isHidden: Bool
    public var compatibility: Compatibility
    public var note: String
    /// Store the spec as well as the ID so changed launch metadata prompts again.
    public var preferredLaunchOption: LaunchOption?
    public var controllerMode: ControllerMode?
    public init(isFavorite: Bool = false, isHidden: Bool = false, compatibility: Compatibility = .untested, note: String = "") {
        self.isFavorite = isFavorite; self.isHidden = isHidden; self.compatibility = compatibility; self.note = note
    }
}

public enum LibraryScope: Codable, Hashable, Sendable { case installed, all, favorites, hidden, collection(UUID) }
public enum LibrarySort: String, Codable, CaseIterable, Sendable {
    case name, recentlyPlayed, playtime, recentlyAdded
    public var title: String {
        switch self { case .name: "Name"; case .recentlyPlayed: "Recently played"; case .playtime: "Playtime"; case .recentlyAdded: "Recently added" }
    }
}
public struct LibraryPreferences: Codable, Equatable, Sendable {
    public var scope: LibraryScope = .all
    public var sort: LibrarySort = .name
    public var refinements: LibraryRefinements?
    public var reducedMotion = false
    public var downloadWhilePlaying = false
    public var selectedDisplayID: UInt32?
    public var selectedDisplayUUID: String?
    public var selectedDisplayName: String?
    public var selectedAudioDeviceUID: String?
    public var selectedAudioDeviceName: String?
    /// Nil preserves the fullscreen default for profiles created before this setting existed.
    public var startInFullscreen: Bool?
    public var gamesVolume: GamesVolumeSelection?
    public var setupCompleted = false
    public init() {}
}

public struct CatalogEntry: Equatable, Sendable, Identifiable {
    public var id: GameID { source.id }
    public let source: SourceGameRecord
    public let edits: GameEdits
    public let installation: InstallationRecord?
    public let localPlaytimeSeconds: Int64
    public let lastSession: PlaySessionRecord?
    public var totalPlaytimeSeconds: Int64 { source.importedPlaytimeSeconds + localPlaytimeSeconds }
    public var lastPlayedAt: Date? { [source.sourceLastPlayedAt, lastSession?.startedAt].compactMap { $0 }.max() }
    public init(source: SourceGameRecord, edits: GameEdits, installation: InstallationRecord?, localPlaytimeSeconds: Int64, lastSession: PlaySessionRecord?) {
        self.source = source; self.edits = edits; self.installation = installation
        self.localPlaytimeSeconds = localPlaytimeSeconds; self.lastSession = lastSession
    }
}
public struct CatalogSnapshot: Sendable {
    public let entries: [CatalogEntry]
    public let collections: [GameCollection]
    public let preferences: LibraryPreferences
    public init(entries: [CatalogEntry], collections: [GameCollection], preferences: LibraryPreferences) {
        self.entries = entries; self.collections = collections; self.preferences = preferences
    }
}
