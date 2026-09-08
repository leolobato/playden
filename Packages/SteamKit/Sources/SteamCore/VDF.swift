import Foundation

/// Valve KeyValues (text VDF) — the format of PICS appinfo buffers.
public indirect enum VDF {
    case string(String)
    case dict([(String, VDF)])

    public subscript(key: String) -> VDF? {
        if case .dict(let entries) = self {
            return entries.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
        }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var entries: [(String, VDF)] {
        if case .dict(let e) = self { return e }
        return []
    }

    public var uint64Value: UInt64? { stringValue.flatMap { UInt64($0) } }

    public static func parse(_ text: String) throws -> VDF {
        var parser = Parser(text: Array(text.unicodeScalars))
        var entries: [(String, VDF)] = []
        while let pair = try parser.parsePair() { entries.append(pair) }
        return .dict(entries)
    }

    private struct Parser {
        let text: [Unicode.Scalar]
        var pos = 0

        mutating func skipWhitespaceAndComments() {
            while pos < text.count {
                let c = text[pos]
                if c == " " || c == "\t" || c == "\n" || c == "\r" { pos += 1; continue }
                if c == "/" && pos + 1 < text.count && text[pos + 1] == "/" {
                    while pos < text.count && text[pos] != "\n" { pos += 1 }
                    continue
                }
                break
            }
        }

        mutating func parseToken() throws -> String? {
            skipWhitespaceAndComments()
            guard pos < text.count else { return nil }
            if text[pos] == "\"" {
                pos += 1
                var out = String.UnicodeScalarView()
                while pos < text.count && text[pos] != "\"" {
                    if text[pos] == "\\" && pos + 1 < text.count {
                        pos += 1
                        switch text[pos] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "\\": out.append("\\")
                        case "\"": out.append("\"")
                        default: out.append("\\"); out.append(text[pos])
                        }
                    } else {
                        out.append(text[pos])
                    }
                    pos += 1
                }
                guard pos < text.count else { throw SteamError.protocolError("VDF: unterminated string") }
                pos += 1
                return String(out)
            }
            if text[pos] == "{" || text[pos] == "}" { pos += 1; return String(text[pos - 1]) }
            var out = String.UnicodeScalarView()
            while pos < text.count, !" \t\n\r{}\"".unicodeScalars.contains(text[pos]) {
                out.append(text[pos])
                pos += 1
            }
            return out.isEmpty ? nil : String(out)
        }

        /// Parses one `key value` or `key { ... }` pair; nil at end or closing brace.
        mutating func parsePair() throws -> (String, VDF)? {
            let save = pos
            guard let key = try parseToken() else { return nil }
            if key == "}" { pos = save; return nil }
            guard let next = try parseToken() else { throw SteamError.protocolError("VDF: key without value") }
            if next == "{" {
                var entries: [(String, VDF)] = []
                while let pair = try parsePair() { entries.append(pair) }
                skipWhitespaceAndComments()
                guard pos < text.count, text[pos] == "}" else { throw SteamError.protocolError("VDF: missing }") }
                pos += 1
                return (key, .dict(entries))
            }
            return (key, .string(next))
        }
    }
}
