import Foundation
import Darwin
import Domain
import Runner

public struct SavedFile: Codable, Equatable, Sendable {
    public let root: SaveRoot
    public let path: String
    public let modifiedAt: Date
    public let bytes: Int64
    public let sha256: Data
    public let sha1: Data
}

public struct SaveSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let version: Int
    public let id: UUID
    public let gameID: GameID
    public let installationID: UUID
    public let createdAt: Date
    public let mapping: SaveMapping
    public let files: [SavedFile]
    /// Present only for a downloaded Cloud staging copy. Local snapshots do not imply account
    /// attachment; the Catalog journal owns that consent and the successful sync baseline.
    public var cloud: CloudFileList? = nil
    public var retainedBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

/// Verified staging copies, independent of Cloud account journals. Callers must first claim the game's
/// maintenance/session lock and verify ownership of every supplied game/bottle root. Metadata
/// mappings can be backed up, but cannot authorize deletion of unresolved storage.
public actor SaveStore {
    private let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Big Screen/saves")) { self.root = root }

    public func snapshot(gameID: GameID, installationID: UUID, mapping: SaveMapping,
                         roots: [SaveRoot: URL], id: UUID = UUID()) throws -> SaveSnapshot {
        try validate(mapping)
        let store = try gameDirectory(gameID, create: true)
        if try store.info(id.uuidString) != nil {
            let existing = try verified(id, gameID: gameID)
            guard existing.installationID == installationID, existing.mapping == mapping, existing.cloud == nil else {
                throw saveFailure("This save backup belongs to a different operation.")
            }
            return existing
        }
        let sources = try open(roots)
        let selected = try select(mapping, in: sources)
        // An interrupted unpublished copy is never a usable backup. A retry gets a new staging
        // folder; only a complete, verified manifest is published under the operation's ID.
        let temporary = ".partial-\(UUID().uuidString)"
        guard mkdirat(store.fd, temporary, 0o700) == 0,
              let staging = try store.directory(temporary) else { throw SaveDirectory.posix() }
        var published = false
        defer { if !published { try? store.discardStaging(temporary) } }
        var entries: [SavedFile] = []
        for (index, location) in selected.enumerated() {
            try Task.checkCancellation()
            guard let file = try sources[location.root]?.file(location.path) else {
                throw saveFailure("A save disappeared before its backup finished. The original folders have been kept.")
            }
            var digest: SaveDigest?
            try staging.write("files/\(index)") { destination in
                digest = try file.stream { try SaveDirectory.writeAll($0, to: destination) }
            }
            guard let digest else { throw saveFailure("A save backup did not finish.") }
            entries.append(SavedFile(root: location.root, path: location.path, modifiedAt: file.modifiedAt,
                                     bytes: digest.bytes, sha256: digest.sha256, sha1: digest.sha1))
        }
        guard try select(mapping, in: sources) == selected else {
            throw saveFailure("The save file list changed during backup. Close the game and try again.")
        }
        for entry in entries {
            guard let file = try sources[entry.root]?.file(entry.path), try file.stream() == digest(entry) else {
                throw saveFailure("A save changed before its backup finished. Close the game and try again.")
            }
        }
        let snapshot = SaveSnapshot(version: 1, id: id, gameID: gameID, installationID: installationID,
                                    createdAt: .now, mapping: mapping, files: entries)
        try staging.write(JSONEncoder().encode(snapshot), to: "manifest.json")
        try verifyFiles(snapshot, in: staging)
        guard fsync(staging.fd) == 0,
              renameatx_np(store.fd, temporary, store.fd, id.uuidString, UInt32(RENAME_EXCL)) == 0,
              fsync(store.fd) == 0 else { throw SaveDirectory.posix() }
        published = true
        return snapshot
    }

    public func verified(_ id: UUID, gameID: GameID) throws -> SaveSnapshot {
        let store = try gameDirectory(gameID)
        guard let archive = try store.directory(id.uuidString), let manifest = try archive.file("manifest.json") else {
            throw saveFailure("The retained save backup is missing.")
        }
        let snapshot = try JSONDecoder().decode(SaveSnapshot.self, from: manifest.contents(maximum: 16 * 1024 * 1024))
        guard snapshot.version == 1, snapshot.id == id, snapshot.gameID == gameID else {
            throw saveFailure("The retained save backup does not match this game.")
        }
        try validate(snapshot.mapping)
        try verifyFiles(snapshot, in: archive)
        return snapshot
    }

    /// Preflights every file before writing. Identical files are idempotent; different local
    /// content is a conflict, regardless of its timestamp. Retained copies are never consumed.
    public func restore(_ id: UUID, gameID: GameID, roots: [SaveRoot: URL]) throws -> SaveSnapshot {
        let snapshot = try verified(id, gameID: gameID)
        let destinations = try open(roots)
        for entry in snapshot.files {
            guard let destination = destinations[entry.root] else { throw saveFailure("A save destination is unavailable.") }
            if let existing = try destination.file(entry.path), try existing.stream() != digest(entry) {
                throw saveFailure("A different local save already exists. Both copies have been kept; choose which save to use.")
            }
        }
        let store = try gameDirectory(gameID)
        guard let archive = try store.directory(id.uuidString) else { throw saveFailure("The retained save backup is missing.") }
        for (index, entry) in snapshot.files.enumerated() {
            try Task.checkCancellation()
            guard let destination = destinations[entry.root] else { throw saveFailure("A save destination is unavailable.") }
            if let existing = try destination.file(entry.path) {
                guard try existing.stream() == digest(entry) else { throw saveFailure("A local save changed during restore. Both copies have been kept.") }
                continue
            }
            guard let source = try archive.file("files/\(index)") else { throw saveFailure("A retained save file is missing.") }
            let expected = digest(entry)
            try destination.write(entry.path) { descriptor in
                guard try source.stream({ try SaveDirectory.writeAll($0, to: descriptor) }) == expected else {
                    throw saveFailure("A retained save file changed during restore.")
                }
                let seconds = entry.modifiedAt.timeIntervalSince1970
                let whole = floor(seconds)
                var times = [timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1e9)),
                             timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1e9))]
                guard futimens(descriptor, &times) == 0 else { throw SaveDirectory.posix() }
            }
        }
        return snapshot
    }

    struct Location: Equatable {
        let root: SaveRoot
        let path: String
        var key: String { root.rawValue + "/" + path.lowercased() }
    }
    func select(_ mapping: SaveMapping, in roots: [SaveRoot: SaveDirectory]) throws -> [Location] {
        var locations: [String: Location] = [:]
        func walk(_ directory: SaveDirectory, prefix: String, rule: SaveRule) throws {
            for name in try directory.names() {
                try Task.checkCancellation()
                if SaveDirectory.isSaveTemporary(name) { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                _ = try SaveDirectory.components(path)
                guard let info = try directory.info(name) else { throw saveFailure("A save disappeared during scanning.") }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFDIR {
                    if rule.recursive, let child = try directory.directory(name) { try walk(child, prefix: path, rule: rule) }
                } else if kind == S_IFLNK || fnmatch(rule.pattern.lowercased(), name.lowercased(), 0) == 0 {
                    guard kind == S_IFREG, info.st_nlink == 1 else {
                        throw saveFailure("A save location contains a link or a special file. The original folders have been kept.")
                    }
                    let location = Location(root: rule.root, path: path)
                    if let previous = locations[location.key], previous != location {
                        throw saveFailure("Two save filenames differ only in letter case. The original folders have been kept.")
                    }
                    locations[location.key] = location
                }
            }
        }
        for rule in mapping.rules {
            guard let root = roots[rule.root] else { throw saveFailure("A save source is unavailable.") }
            if let directory = try root.directory(rule.directory) { try walk(directory, prefix: rule.directory, rule: rule) }
        }
        return locations.values.sorted { $0.key < $1.key }
    }
    func validate(_ mapping: SaveMapping) throws {
        guard mapping.rules.count <= 1024 else { throw saveFailure("There are too many save locations.") }
        for rule in mapping.rules {
            _ = try SaveDirectory.components(rule.directory)
            guard !rule.pattern.isEmpty, rule.pattern != ".", rule.pattern != "..",
                  rule.pattern.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\0:[]{}")) == nil else {
                throw saveFailure("A save filename pattern is unsupported.")
            }
        }
    }
    func verifyFiles(_ snapshot: SaveSnapshot, in archive: SaveDirectory) throws {
        var keys = Set<String>(), total: Int64 = 0
        for (index, entry) in snapshot.files.enumerated() {
            let parts = try SaveDirectory.components(entry.path)
            let key = Location(root: entry.root, path: entry.path).key
            let sum = total.addingReportingOverflow(entry.bytes)
            guard !parts.isEmpty, keys.insert(key).inserted, entry.bytes >= 0, !sum.overflow,
                  entry.sha256.count == 32, entry.sha1.count == 20,
                  entry.modifiedAt.timeIntervalSince1970.isFinite,
                  abs(entry.modifiedAt.timeIntervalSince1970) < 1e12,
                  snapshot.mapping.rules.contains(where: { matches(entry, rule: $0) }),
                  let file = try archive.file("files/\(index)"), try file.stream() == digest(entry) else {
                throw saveFailure("A retained save file failed verification. The original folders have been kept.")
            }
            total = sum.partialValue
        }
    }
    private func matches(_ entry: SavedFile, rule: SaveRule) -> Bool {
        guard entry.root == rule.root else { return false }
        let prefix = rule.directory.isEmpty ? "" : rule.directory + "/"
        guard entry.path.hasPrefix(prefix) else { return false }
        let suffix = String(entry.path.dropFirst(prefix.count))
        guard rule.recursive || !suffix.contains("/") else { return false }
        return fnmatch(rule.pattern.lowercased(), String(suffix.split(separator: "/").last ?? "").lowercased(), 0) == 0
    }
    func digest(_ entry: SavedFile) -> SaveDigest { .init(bytes: entry.bytes, sha256: entry.sha256, sha1: entry.sha1) }
    func open(_ roots: [SaveRoot: URL]) throws -> [SaveRoot: SaveDirectory] {
        try roots.mapValues { try SaveDirectory(url: $0) }
    }
    func gameDirectory(_ id: GameID, create: Bool = false) throws -> SaveDirectory {
        let parent = try SaveDirectory(url: root, create: create)
        guard let result = try parent.directory(CrossOverGameBottles.name(for: id), create: create) else {
            throw saveFailure("This game has no retained save backup.")
        }
        return result
    }
}
