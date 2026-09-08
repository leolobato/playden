import Foundation
import Darwin
import Domain

/// Bidirectional Steam UFS name mapping. This resolves names only; SaveDirectory still verifies
/// every filesystem component beneath an ownership-checked game/bottle root before accessing it.
public struct CloudSavePaths: Sendable {
    private let rules: [SaveRule]
    public init(mapping: SaveMapping) throws {
        guard mapping.coverage != .unknown, mapping.unresolved.isEmpty else {
            throw saveFailure("This game's Cloud save locations are not fully known. Local saves have been kept.")
        }
        rules = mapping.rules.filter { $0.cloudPrefix != nil }
        guard !rules.isEmpty else { throw saveFailure("This game has no supported Cloud save locations.") }
        for rule in rules {
            _ = try Self.components(rule.directory)
            _ = try Self.normalized(rule.cloudPrefix!)
            guard !rule.pattern.isEmpty, rule.pattern != ".", rule.pattern != "..",
                  rule.pattern.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\0:[]{}\r\n")) == nil else {
                throw saveFailure("A Cloud save filename pattern is unsupported.")
            }
        }
    }

    public func localPath(for remoteName: String) throws -> CloudSavePath? {
        let name = try Self.normalized(remoteName)
        var matches: [(Int, CloudSavePath)] = []
        for rule in rules {
            let prefix = try Self.normalized(rule.cloudPrefix!)
            guard let suffix = Self.suffix(name, after: prefix), Self.matches(suffix, rule: rule) else { continue }
            let local = [rule.directory, suffix].filter { !$0.isEmpty }.joined(separator: "/")
            _ = try Self.components(local)
            matches.append((prefix.count, CloudSavePath(root: rule.root, path: local)))
        }
        guard let length = matches.map(\.0).max() else { return nil }
        let paths = matches.filter { $0.0 == length }.map(\.1)
        guard Set(paths.map(\.key)).count == 1 else { throw saveFailure("A Cloud save matches more than one local destination.") }
        return paths.first
    }

    public func remoteName(for location: CloudSavePath) throws -> String? {
        _ = try Self.components(location.path)
        var names = Set<String>()
        for rule in rules where rule.root == location.root {
            guard let suffix = Self.suffix(location.path, after: rule.directory), Self.matches(suffix, rule: rule) else { continue }
            let prefix = rule.cloudPrefix!.replacingOccurrences(of: "\\", with: "/")
            let name = prefix + (prefix.isEmpty || prefix.hasSuffix("/") ? "" : "/") + suffix
            if try localPath(for: name)?.key == location.key { names.insert(name) }
        }
        guard names.count <= 1 else { throw saveFailure("A local save matches more than one Cloud filename.") }
        return names.first
    }

    /// Steam uses both %Root%/folder and %Root%folder; normalize only that root separator.
    /// Do not collapse traversal, absolute paths, repeated separators or unresolved placeholders.
    private static func normalized(_ raw: String) throws -> String {
        let name = raw.replacingOccurrences(of: "\\", with: "/")
        if name.hasPrefix("%") {
            guard let end = name.dropFirst().firstIndex(of: "%") else { throw saveFailure("A Cloud root token is incomplete.") }
            let root = String(name[...end])
            let token = root.dropFirst().dropLast()
            guard !token.isEmpty, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw saveFailure("A Cloud root token is invalid.")
            }
            var remainder = String(name[name.index(after: end)...])
            if remainder.hasPrefix("/") { remainder.removeFirst() }
            _ = try components(remainder)
            // A slash after the token makes root-only prefix matching unambiguous.
            return root + (remainder.isEmpty ? "" : "/" + remainder)
        }
        _ = try components(name)
        return name
    }
    private static func components(_ path: String) throws -> [String] {
        guard path.rangeOfCharacter(from: CharacterSet(charactersIn: "%{}*?<>|\r\n")) == nil else {
            throw saveFailure("A Cloud save path contains unsupported characters or unresolved placeholders.")
        }
        let parts = try SaveDirectory.components(path)
        guard !parts.contains(where: SaveDirectory.isSaveTemporary) else {
            throw saveFailure("A Cloud path uses a reserved save staging name.")
        }
        return parts
    }
    private static func suffix(_ name: String, after prefix: String) -> String? {
        if prefix.isEmpty { return name.isEmpty ? nil : name }
        let start = prefix.hasSuffix("/") ? prefix : prefix + "/"
        guard name.lowercased().hasPrefix(start.lowercased()) else { return nil }
        return String(name.dropFirst(start.count))
    }
    private static func matches(_ suffix: String, rule: SaveRule) -> Bool {
        guard !suffix.isEmpty, rule.recursive || !suffix.contains("/") else { return false }
        return fnmatch(rule.pattern.lowercased(), String(suffix.split(separator: "/").last ?? "").lowercased(), 0) == 0
    }
}
