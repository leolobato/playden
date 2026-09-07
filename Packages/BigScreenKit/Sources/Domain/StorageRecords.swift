import Foundation

public struct GamesVolumeSelection: Codable, Equatable, Sendable {
    public var volumeID: String
    public var rootBookmark: Data
    public var lastKnownRoot: URL
    public var relativeRoot: String
    public init(volumeID: String, rootBookmark: Data, lastKnownRoot: URL, relativeRoot: String) {
        self.volumeID = volumeID; self.rootBookmark = rootBookmark; self.lastKnownRoot = lastKnownRoot; self.relativeRoot = relativeRoot
    }
}
public struct GamesVolume: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var mountURL: URL
    public var gamesRoot: URL
    public var freeBytes: Int64
    public var isRecommended: Bool
    public init(id: String, name: String, mountURL: URL, gamesRoot: URL, freeBytes: Int64, isRecommended: Bool = false) {
        self.id = id; self.name = name; self.mountURL = mountURL; self.gamesRoot = gamesRoot
        self.freeBytes = freeBytes; self.isRecommended = isRecommended
    }
}
public protocol VolumeManaging: Sendable {
    func availableVolumes() async throws -> [GamesVolume]
    func select(_ volume: GamesVolume) async throws -> GamesVolumeSelection
    func resolve(_ selection: GamesVolumeSelection) async throws -> URL
}
