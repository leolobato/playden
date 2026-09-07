import Foundation

public struct GameID: Hashable, Codable, Sendable {
    public let source: String
    public let value: String
    public init(source: String, value: String) { self.source = source; self.value = value }
}

public enum InstallStatus: String, Codable, Sendable {
    case notInstalled, installed, queued, downloading, driveDisconnected
}

public enum Compatibility: String, CaseIterable, Codable, Sendable {
    case untested = "Untested", works = "Works", playable = "Playable", broken = "Broken"
}

public struct Game: Identifiable, Hashable, Sendable {
    public let id: GameID
    public var title: String
    public var status: InstallStatus
    public var compatibility: Compatibility
    public var hoursPlayed: Int
    public var size: String
    public var summary: String
    public var genres: [String]
    public var coverURL: URL?
    public var heroURL: URL?
    public var logoURL: URL?
    public var isFavorite: Bool
    public var isHidden: Bool

    public init(id: GameID, title: String, status: InstallStatus = .notInstalled,
                compatibility: Compatibility = .untested, hoursPlayed: Int = 0, size: String = "—",
                summary: String = "", genres: [String] = [], coverURL: URL? = nil,
                heroURL: URL? = nil, logoURL: URL? = nil, isFavorite: Bool = false, isHidden: Bool = false) {
        self.id = id; self.title = title; self.status = status; self.compatibility = compatibility
        self.hoursPlayed = hoursPlayed; self.size = size; self.summary = summary; self.genres = genres
        self.coverURL = coverURL; self.heroURL = heroURL; self.logoURL = logoURL
        self.isFavorite = isFavorite; self.isHidden = isHidden
    }
}
