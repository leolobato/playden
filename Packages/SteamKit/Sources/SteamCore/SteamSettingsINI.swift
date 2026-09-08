import Foundation

/// Updates generated settings without replacing unrelated game-specific options or comments.
public enum SteamSettingsINI {
    public static func write(_ generated: String, to url: URL, replacingSections: Set<String> = [],
                             removingKeys: [String: Set<String>] = [:]) throws {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try manager.attributesOfItem(atPath: url.path) }
        catch CocoaError.fileReadNoSuchFile {
            try Data(generated.utf8).write(to: url, options: .atomic)
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SteamError.prepare("settings file is not a regular file: \(url.lastPathComponent)")
        }
        let original = try Data(contentsOf: url)
        let bom = Data([0xef, 0xbb, 0xbf])
        let hasBOM = original.starts(with: bom)
        guard let existing = String(data: hasBOM ? Data(original.dropFirst(3)) : original, encoding: .utf8) else {
            throw SteamError.prepare("settings file is not UTF-8; original kept: \(url.lastPathComponent)")
        }
        let merged = merge(generated, into: existing, replacingSections: replacingSections, removingKeys: removingKeys)
        var output = hasBOM ? bom : Data()
        output.append(contentsOf: merged.utf8)
        if output != original { try output.write(to: url, options: .atomic) }
    }

    private struct Line {
        var body: String
        var ending: String
    }
    private static func lines(_ text: String) -> [Line] {
        var result: [Line] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { _, range, enclosing, _ in
            result.append(Line(body: String(text[range]), ending: String(text[range.upperBound..<enclosing.upperBound])))
        }
        return result
    }
    private static func section(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "[", let end = trimmed.firstIndex(of: "]") else { return nil }
        let suffix = trimmed[trimmed.index(after: end)...].trimmingCharacters(in: .whitespaces)
        guard suffix.isEmpty || suffix.hasPrefix(";") || suffix.hasPrefix("#") else { return nil }
        return trimmed[trimmed.index(after: trimmed.startIndex)..<end].trimmingCharacters(in: .whitespaces).lowercased()
    }
    private static func key(_ line: String) -> (name: String, equal: String.Index)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { return nil }
        let name = line[..<equal].trimmingCharacters(in: .whitespaces).lowercased()
        return name.isEmpty ? nil : (name, equal)
    }
    private static func replaceValue(_ line: String, equal: String.Index, with value: String) -> String {
        let rhs = line[line.index(after: equal)...]
        // An embedded delimiter can be part of a path or account name. Only preserve
        // a trailing comment separated from the previous value by whitespace.
        let comment = rhs.indices.first { index in
            (rhs[index] == ";" || rhs[index] == "#") && index > rhs.startIndex &&
                rhs[rhs.index(before: index)].isWhitespace &&
                !rhs[..<index].trimmingCharacters(in: .whitespaces).isEmpty
        } ?? rhs.endIndex
        let previous = rhs[..<comment]
        let leading = previous.prefix(while: \.isWhitespace)
        let trailing = previous.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(previous.reversed().prefix(while: \.isWhitespace).reversed())
        return String(line[...equal]) + leading + value + trailing + rhs[comment...]
    }

    static func merge(_ generated: String, into existing: String, replacingSections: Set<String> = [],
                      removingKeys: [String: Set<String>] = [:]) -> String {
        let generatedLines = lines(generated)
        var order: [String] = [], values: [String: [(name: String, value: String, line: String)]] = [:]
        var current = ""
        for line in generatedLines {
            if let name = section(line.body) {
                current = name
                if values[name] == nil { values[name] = []; order.append(name) }
            } else if let key = key(line.body) {
                if values[current] == nil { values[current] = []; order.append(current) }
                values[current, default: []].append((key.name, line.body[line.body.index(after: key.equal)...].trimmingCharacters(in: .whitespaces), line.body))
            }
        }
        let replace = Set(replacingSections.map { $0.lowercased() })
        var removals: [String: Set<String>] = [:]
        for (name, keys) in removingKeys { removals[name.lowercased(), default: []].formUnion(keys.map { $0.lowercased() }) }
        var seen: [String: Set<String>] = [:], result: [Line] = []
        current = ""
        for var line in lines(existing) {
            if let name = section(line.body) { current = name }
            else if let key = key(line.body) {
                if let setting = values[current]?.first(where: { $0.name == key.name }) {
                    line.body = replaceValue(line.body, equal: key.equal, with: setting.value)
                    seen[current, default: []].insert(key.name)
                } else if replace.contains(current) || removals[current]?.contains(key.name) == true { continue }
            }
            result.append(line)
        }
        let ending = result.first(where: { !$0.ending.isEmpty })?.ending ?? generatedLines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
        for name in order {
            let missing = (values[name] ?? []).filter { seen[name]?.contains($0.name) != true }
            guard !missing.isEmpty else { continue }
            let start = result.firstIndex { section($0.body) == name }
            let insertion = name.isEmpty ? (result.firstIndex { section($0.body) != nil } ?? result.count) :
                (start.flatMap { index in result.indices.dropFirst(index + 1).first { section(result[$0].body) != nil } } ?? result.count)
            if insertion > 0, result[insertion - 1].ending.isEmpty { result[insertion - 1].ending = ending }
            let heading = start == nil && !name.isEmpty ? [Line(body: "[\(name)]", ending: ending)] : []
            result.insert(contentsOf: heading + missing.map { Line(body: $0.line, ending: ending) }, at: insertion)
        }
        return result.map { $0.body + $0.ending }.joined()
    }
}
