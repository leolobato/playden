import Foundation

public struct DownloadSizeEstimate: Codable, Equatable, Sendable {
    public let accountKey: String
    public let bytes: Int64?
    public let manifestIDs: [String: String]
    public let precise: Bool
    public var checkedAt: Date
    public init(accountKey: String, bytes: Int64?, manifestIDs: [String: String], precise: Bool = false, checkedAt: Date = .now) {
        self.accountKey = accountKey; self.bytes = bytes; self.manifestIDs = manifestIDs
        self.precise = precise; self.checkedAt = checkedAt
    }
    public func isFresh(at date: Date = .now) -> Bool {
        date >= checkedAt && date.timeIntervalSince(checkedAt) < (bytes == nil ? 900 : 6 * 3600)
    }
}
