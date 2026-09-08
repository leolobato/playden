import Foundation

/// Identity is recorded before a clone starts and reused on retry and cleanup.
public struct GameBottle: Codable, Equatable, Sendable {
    public let gameID: GameID
    public let name: String
    public let ownershipToken: UUID
    public let templateVersion: String
    public init(gameID: GameID, name: String, ownershipToken: UUID, templateVersion: String = "1") {
        self.gameID = gameID; self.name = name; self.ownershipToken = ownershipToken; self.templateVersion = templateVersion
    }
}
