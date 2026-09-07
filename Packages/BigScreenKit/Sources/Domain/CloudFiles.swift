import Foundation

/// Remote names are opaque store identifiers, never filesystem paths. A verified save mapping
/// must translate them before any local read or write.
public struct CloudFile: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case present, forgotten, deleted }
    public let name: String
    public let sha1: Data
    public let bytes: Int64
    public let modifiedAt: Date
    public let state: State
    public let requiresUpload: Bool
    public init(name: String, sha1: Data, bytes: Int64, modifiedAt: Date, state: State = .present,
                requiresUpload: Bool = false) {
        self.name = name; self.sha1 = sha1; self.bytes = bytes; self.modifiedAt = modifiedAt
        self.state = state; self.requiresUpload = requiresUpload
    }
}

public struct CloudFileList: Codable, Equatable, Sendable {
    public let gameID: GameID
    /// Opaque account key. Credentials and the raw store account identity stay inside Sources.
    public let accountKey: String
    public let revision: UInt64
    public let files: [CloudFile]
    public init(gameID: GameID, accountKey: String, revision: UInt64, files: [CloudFile]) {
        self.gameID = gameID; self.accountKey = accountKey; self.revision = revision; self.files = files
    }
}

public protocol CloudReading: Sendable {
    func files(for gameID: GameID) async throws -> CloudFileList
    /// Returns validated bytes only. Does not replace local saves or advance the sync baseline.
    func download(_ file: CloudFile, from list: CloudFileList) async throws -> Data
}
