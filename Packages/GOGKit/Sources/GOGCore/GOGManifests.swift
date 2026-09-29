import Foundation

/// A number GOG writes as an integer in some manifests and as a string in others.
public struct GOGNumber: Decodable, Equatable, Sendable {
    public var value: Int64
    public init(_ value: Int64) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int64.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = Int64(v) }
        else if let s = try? c.decode(String.self), let v = Int64(s) { value = v }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a number") }
    }
}

/// An ID GOG writes as a string or a number.
public struct GOGID: Decodable, Equatable, Hashable, Sendable {
    public var value: String
    public init(_ value: String) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else { value = String(try c.decode(Int64.self)) }
    }
}

// MARK: Generation 2

/// The build manifest ("repository") of a gen 2 build.
public struct GOGBuildManifestV2: Decodable, Sendable {
    public struct Product: Decodable, Sendable { public var productId: GOGID; public var name: String? }
    public struct Depot: Decodable, Sendable {
        public var productId: GOGID
        public var languages: [String]
        public var manifest: String
        public var size: GOGNumber?
        public var compressedSize: GOGNumber?
        public var osBitness: [String]?
        public var isGogDepot: Bool?
    }
    public var baseProductId: GOGID
    public var buildId: GOGID?
    public var installDirectory: String
    public var platform: String?
    public var dependencies: [String]?
    public var products: [Product]?
    public var depots: [Depot]
    public var scriptInterpreter: Bool?
}

public struct GOGChunk: Codable, Equatable, Sendable {
    public var md5: String
    public var compressedMd5: String
    public var size: Int64
    public var compressedSize: Int64
    public init(md5: String, compressedMd5: String, size: Int64, compressedSize: Int64) {
        self.md5 = md5; self.compressedMd5 = compressedMd5; self.size = size; self.compressedSize = compressedSize
    }
}

/// A gen 2 depot manifest: files, directories and links.
public struct GOGDepotManifestV2: Decodable, Sendable {
    public struct Item: Decodable, Sendable {
        struct RawChunk: Decodable { var md5: String; var compressedMd5: String; var size: GOGNumber; var compressedSize: GOGNumber }
        public var type: String
        public var path: String
        public var target: String?
        public var md5: String?
        public var sha256: String?
        public var flags: [String]?
        public var chunks: [GOGChunk]

        enum CodingKeys: String, CodingKey { case type, path, target, md5, sha256, flags, chunks }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            path = try c.decode(String.self, forKey: .path)
            target = try c.decodeIfPresent(String.self, forKey: .target)
            md5 = try c.decodeIfPresent(String.self, forKey: .md5)
            sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
            flags = try c.decodeIfPresent([String].self, forKey: .flags)
            chunks = (try c.decodeIfPresent([RawChunk].self, forKey: .chunks) ?? []).map {
                GOGChunk(md5: $0.md5, compressedMd5: $0.compressedMd5, size: $0.size.value, compressedSize: $0.compressedSize.value)
            }
        }
    }
    struct Body: Decodable { var items: [Item] }
    var depot: Body
    public var items: [Item] { depot.items }
}

// MARK: Generation 1

/// The repository of a gen 1 build. `redist` depots name dependencies instead of holding files.
public struct GOGRepositoryV1: Decodable, Sendable {
    public struct Depot: Decodable, Sendable {
        public var languages: [String]?
        public var manifest: String?
        public var gameIDs: [GOGID]?
        public var size: GOGNumber?
        public var systems: [String]?
        public var redist: String?
    }
    public struct GameID: Decodable, Sendable { public var gameID: GOGID }
    public struct Product: Decodable, Sendable {
        public var rootGameID: GOGID
        public var timestamp: GOGNumber
        public var installDirectory: String
        public var gameIDs: [GameID]?
        public var depots: [Depot]
    }
    public var product: Product
}

public struct GOGDepotManifestV1: Decodable, Sendable {
    public struct File: Decodable, Sendable {
        public var path: String
        public var offset: GOGNumber?
        public var size: GOGNumber?
        public var hash: String?
        public var url: String?
        public var executable: Bool?
        public var support: Bool?
        public var directory: Bool?
        public var target: String?
        public var symlinkType: String?
    }
    struct Body: Decodable { var files: [File] }
    var depot: Body
    public var files: [File] { depot.files }
}

// MARK: Dependencies

/// The dependency repository: redistributables and game-folder tools such as DOSBox and ScummVM.
public struct GOGDependencyRepository: Decodable, Sendable {
    public struct Depot: Decodable, Sendable {
        public struct Executable: Decodable, Sendable { public var path: String?; public var arguments: String? }
        public var dependencyId: String
        public var executable: Executable?
        public var manifest: String
        public var size: GOGNumber?
        public var compressedSize: GOGNumber?
        /// Entries with an executable under `__redist` are installers; the others are files the game folder needs.
        public var isGameFolderDependency: Bool {
            let path = executable?.path ?? ""
            return !path.replacingOccurrences(of: "\\", with: "/").lowercased().hasPrefix("__redist")
        }
    }
    public var depots: [Depot]
}

// MARK: Launch tasks

/// `goggame-<id>.info`: the tasks the Galaxy client offers for a product.
public struct GOGInfoFile: Codable, Equatable, Sendable {
    public struct Task: Codable, Equatable, Sendable {
        public var type: String?
        public var category: String?
        public var isPrimary: Bool?
        public var isHidden: Bool?
        public var name: String?
        public var path: String?
        public var workingDir: String?
        public var arguments: String?
        public var link: String?
        public init(type: String? = "FileTask", category: String? = nil, isPrimary: Bool? = nil, isHidden: Bool? = nil, name: String? = nil,
                    path: String? = nil, workingDir: String? = nil, arguments: String? = nil, link: String? = nil) {
            self.type = type; self.category = category; self.isPrimary = isPrimary; self.isHidden = isHidden; self.name = name
            self.path = path; self.workingDir = workingDir; self.arguments = arguments; self.link = link
        }
        public var isFileTask: Bool { (type ?? "FileTask") == "FileTask" && !(path ?? "").isEmpty }
    }
    public var gameId: String?
    public var name: String?
    public var playTasks: [Task]

    enum CodingKeys: String, CodingKey { case gameId, name, playTasks }
    public init(gameId: String? = nil, name: String? = nil, playTasks: [Task]) { self.gameId = gameId; self.name = name; self.playTasks = playTasks }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gameId = (try? c.decodeIfPresent(GOGID.self, forKey: .gameId))??.value
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        playTasks = try c.decodeIfPresent([Task].self, forKey: .playTasks) ?? []
    }

    public static func parse(_ data: Data) throws -> GOGInfoFile {
        // Some info files start with a UTF-8 byte order mark.
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        return try GOGHTTP.decode(GOGInfoFile.self, Data(body))
    }

    /// The primary file task, else the first file task. URL tasks are never launched.
    public var primaryTask: Task? { playTasks.first { $0.isFileTask && $0.isPrimary == true } ?? playTasks.first { $0.isFileTask } }
    /// File tasks a player may pick instead: not hidden, not documents, not the primary one.
    public var optionTasks: [Task] {
        let primary = primaryTask
        return playTasks.filter { $0.isFileTask && $0.isHidden != true && $0.category != "document" && $0 != primary }
    }
}
