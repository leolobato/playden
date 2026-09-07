import Foundation

public struct GameCollection: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var gameIDs: Set<GameID>
    public var isPinned: Bool
    public init(id: UUID = UUID(), name: String, gameIDs: Set<GameID> = [], isPinned: Bool = false) {
        self.id = id; self.name = name; self.gameIDs = gameIDs; self.isPinned = isPinned
    }
}
