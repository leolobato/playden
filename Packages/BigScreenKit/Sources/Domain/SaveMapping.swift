import Foundation

public enum SaveRoot: String, Codable, Sendable { case game, bottle }

/// A source describes paths; the save store resolves them only inside verified owned roots.
/// Cloud prefixes deliberately remain separate: Steam root overrides can change the local path.
public struct SaveRule: Codable, Equatable, Sendable {
    public let root: SaveRoot
    public let directory: String
    public let pattern: String
    public let recursive: Bool
    public let cloudPrefix: String?
    public init(root: SaveRoot, directory: String, pattern: String = "*", recursive: Bool = true,
                cloudPrefix: String? = nil) {
        self.root = root; self.directory = directory; self.pattern = pattern
        self.recursive = recursive; self.cloudPrefix = cloudPrefix
    }
}

public struct SaveMapping: Codable, Equatable, Sendable {
    public enum Coverage: String, Codable, Sendable {
        case unknown, metadata, verifiedRecipe
    }
    public let rules: [SaveRule]
    public let coverage: Coverage
    public let unresolved: [String]
    public init(rules: [SaveRule] = [], coverage: Coverage = .unknown, unresolved: [String] = []) {
        self.rules = rules; self.coverage = coverage; self.unresolved = unresolved
    }
    /// Metadata alone does not prove that all local save/config files have been retained.
    public var permitsRemovingUnmappedFiles: Bool { coverage == .verifiedRecipe && unresolved.isEmpty && !rules.isEmpty }
}
