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
    /// Original account-token rules, retained so recovery can match source metadata to a resolved mapping.
    public let accountTemplateRules: [SaveRule]?
    public let boundAccountKey: String?
    public var declaration: SaveMapping {
        SaveMapping(rules: accountTemplateRules ?? rules, coverage: coverage, unresolved: unresolved)
    }
    public var requiresSteamAccountResolution: Bool {
        rules.contains { rule in
            [rule.directory, rule.cloudPrefix ?? ""].contains { $0.contains("{64BitSteamID}") || $0.contains("{Steam3AccountID}") }
        }
    }
    public init(rules: [SaveRule] = [], coverage: Coverage = .unknown, unresolved: [String] = [],
                accountTemplateRules: [SaveRule]? = nil, boundAccountKey: String? = nil) {
        self.rules = rules; self.coverage = coverage; self.unresolved = unresolved
        self.accountTemplateRules = accountTemplateRules; self.boundAccountKey = boundAccountKey
    }
    /// Metadata alone does not prove that all local save/config files have been retained.
    public var permitsRemovingUnmappedFiles: Bool { coverage == .verifiedRecipe && unresolved.isEmpty && !rules.isEmpty }
}
