import Foundation
import Domain

/// Games the player keeps on this Mac, the folders Playden watches for them, and the apps the
/// player removed. The catalog is replaced on every scan, so this is the durable record.
public struct LocalLibrary: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public enum Origin: Codable, Equatable, Sendable { case manual, folder(UUID), suggested }
        public var id: String
        public var bookmark: Data?
        public var lastKnownPath: URL
        public var volumeUUID: String?
        public var bundleIdentifier: String?
        public var executableName: String?
        public var origin: Origin
        public var addedAt: Date
        public var usesSteam: Bool?
        /// Last title read from the bundle, shown while the app is missing.
        public var title: String?
        public init(id: String = UUID().uuidString, bookmark: Data?, lastKnownPath: URL, volumeUUID: String?, bundleIdentifier: String?,
                    executableName: String?, origin: Origin, addedAt: Date = .now, usesSteam: Bool? = nil) {
            self.id = id; self.bookmark = bookmark; self.lastKnownPath = lastKnownPath; self.volumeUUID = volumeUUID
            self.bundleIdentifier = bundleIdentifier; self.executableName = executableName; self.origin = origin
            self.addedAt = addedAt; self.usesSteam = usesSteam
        }
    }
    public struct Folder: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var bookmark: Data?
        public var lastKnownPath: URL
        public var depth: Int
        public init(id: UUID = UUID(), bookmark: Data?, lastKnownPath: URL, depth: Int = 2) {
            self.id = id; self.bookmark = bookmark; self.lastKnownPath = lastKnownPath; self.depth = depth
        }
    }
    /// Kept so watched folders skip the app, and so adding it again restores its history.
    public struct Removed: Codable, Equatable, Sendable {
        public var id: String
        public var lastKnownPath: URL
        public var bundleIdentifier: String?
        public var executableName: String?
        public var removedAt: Date
        /// Shown in the Removed list. Records from before titles were kept show the file name.
        public var title: String?
        /// The watched folder the game came from, so restoring it makes it a folder game again.
        public var folderID: UUID?
    }
    public var entries: [Entry] = []
    public var folders: [Folder] = []
    public var removed: [Removed] = []
    public var version = 1
    public init() {}
}

public actor LocalLibraryStore {
    private let file: URL
    private var cached: LocalLibrary?
    public init(file: URL) { self.file = file }
    public func load() throws -> LocalLibrary {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: file.path) else { cached = LocalLibrary(); return cached! }
        let value = try JSONDecoder().decode(LocalLibrary.self, from: Data(contentsOf: file))
        cached = value; return value
    }
    public func update<T>(_ change: (inout LocalLibrary) throws -> T) throws -> T {
        var value = try load()
        let result = try change(&value)
        guard value != cached else { return result }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        cached = value
        return result
    }
    /// Reset forgets games, folders and removals. It never touches the apps themselves.
    public func reset() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        cached = LocalLibrary()
    }
}
