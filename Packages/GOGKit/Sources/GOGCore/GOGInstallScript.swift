import Foundation

/// The file actions of a build's `goggame-<id>.script`, the steps Galaxy's script interpreter (ISI)
/// runs after an install. Playden runs the two that only touch the game folder:
/// - `supportData`: copy a support folder into the game (`source`), or create a folder (no `source`);
/// - `setIni`: set one key in an INI file, such as ScummVM's game `path`.
///
/// `setRegistry` and anything else are skipped (PRD 10 FR-GOG-22). Every path must stay inside the
/// game folder or the product's support folder.
public struct GOGInstallScript: Decodable, Sendable {
    public struct Action: Decodable, Sendable {
        public struct Install: Decodable, Sendable {
            public var action: String
            public var arguments: [String: GOGJSON]
        }
        public var name: String?
        public var languages: [String]?
        public var install: Install?
    }
    public var actions: [Action]

    public static func parse(_ data: Data) throws -> GOGInstallScript {
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        return try GOGHTTP.decode(GOGInstallScript.self, Data(body))
    }

    /// Where the script's variables point. `windowsAppPath` is how the game sees its own folder
    /// (`Z:\…` under Wine), used for values written into files.
    public struct Context: Sendable {
        public var gameRoot: URL
        public var supportRoot: URL
        public var productID: String
        public var language: String
        public var windowsAppPath: String?
        public init(gameRoot: URL, supportRoot: URL, productID: String, language: String, windowsAppPath: String?) {
            self.gameRoot = gameRoot; self.supportRoot = supportRoot; self.productID = productID
            self.language = language; self.windowsAppPath = windowsAppPath
        }
    }

    public enum Step: Equatable, Sendable {
        case copyFolder(from: URL, to: URL, overwrite: Bool)
        case createFolder(URL)
        case setINI(file: URL, section: String, key: String, value: String, utf8: Bool)
    }

    /// The steps for this language, with variables filled in. Actions Playden doesn't run are left out.
    /// `skipCopies` leaves out folder copies, for the run before each launch.
    public func steps(_ context: Context, skipCopies: Bool = false) -> [Step] {
        actions.compactMap { action -> Step? in
            guard let install = action.install else { return nil }
            let languages = action.languages ?? ["*"]
            guard languages.contains("*") || languages.contains(where: { $0.caseInsensitiveCompare(context.language) == .orderedSame }) else { return nil }
            let args = install.arguments
            switch install.action {
            case "supportData":
                guard args["type"]?.string == "folder", let target = args["target"]?.string, let to = Self.location(target, context) else { return nil }
                if let source = args["source"]?.string {
                    // Copies run once, at install; before a launch they could overwrite the player's files.
                    guard !skipCopies else { return nil }
                    guard let from = Self.location(source, context) else { return nil }
                    return .copyFolder(from: from, to: to, overwrite: args["overwrite"] == .bool(true))
                }
                return .createFolder(to)
            case "setIni":
                guard let file = args["filename"]?.string, let url = Self.location(file, context),
                      let section = args["section"]?.string, let key = args["keyName"]?.string, let raw = args["keyValue"]?.string else { return nil }
                return .setINI(file: url, section: section, key: key, value: Self.value(raw, context), utf8: args["utf8"] == .bool(true))
            default:
                return nil
            }
        }
    }

    /// Runs the steps. A missing copy source is skipped: Playden already places `app/` support files
    /// in the game folder when it downloads them.
    public func run(_ context: Context, skipCopies: Bool = false) throws {
        let fm = FileManager.default
        for step in steps(context, skipCopies: skipCopies) {
            switch step {
            case .createFolder(let url):
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            case .copyFolder(let from, let to, let overwrite):
                guard let items = fm.enumerator(at: from, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])?.allObjects as? [URL] else { continue }
                for item in items {
                    let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    let relative = String(item.standardizedFileURL.path.dropFirst(from.standardizedFileURL.path.count + 1))
                    let target = to.appendingPathComponent(relative)
                    if fm.fileExists(atPath: target.path) {
                        guard overwrite else { continue }
                        try fm.removeItem(at: target)
                    }
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: item, to: target)
                }
            case .setINI(let file, let section, let key, let value, let utf8):
                let encoding: String.Encoding = utf8 ? .utf8 : .isoLatin1
                let text = (try? String(contentsOf: file, encoding: encoding)) ?? ""
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let data = Self.settingINI(text, section: section, key: key, value: value).data(using: encoding) else { continue }
                try data.write(to: file, options: .atomic)
            }
        }
    }

    /// `{app}`, `{supportDir}` → a URL that must stay inside the game or support folder.
    static func location(_ raw: String, _ context: Context) -> URL? {
        var path = raw.replacingOccurrences(of: "\\", with: "/")
        let bases: [(String, URL)] = [("{app}", context.gameRoot), ("{supportDir}", context.supportRoot)]
        guard let (token, base) = bases.first(where: { path.hasPrefix($0.0) }) else { return nil }
        path = String(path.dropFirst(token.count)).replacingOccurrences(of: "{productID}", with: context.productID)
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains("..") else { return nil }
        return components.reduce(base) { $0.appendingPathComponent($1) }
    }

    /// Values written into files: `{app}` as the game sees its folder.
    static func value(_ raw: String, _ context: Context) -> String {
        var value = raw.replacingOccurrences(of: "{productID}", with: context.productID)
        if let app = context.windowsAppPath { value = value.replacingOccurrences(of: "{app}", with: app) }
        return value
    }

    /// Sets `key=value` in `[section]`, keeping every other line; adds the section or key when missing.
    static func settingINI(_ text: String, section: String, key: String, value: String) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : (text.isEmpty ? "\r\n" : "\n")
        var lines = text.components(separatedBy: newline)
        if lines.last == "" { lines.removeLast() }
        let header = "[\(section)]".lowercased()
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == header }) else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines += ["[\(section)]", "\(key)=\(value)"]
            return lines.joined(separator: newline) + newline
        }
        var end = lines.count
        for index in (start + 1)..<lines.count where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end = index; break }
        if let existing = (start + 1..<end).first(where: {
            lines[$0].split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame } ?? false
        }) {
            lines[existing] = "\(key)=\(value)"
        } else {
            var insert = end
            while insert > start + 1, lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert -= 1 }
            lines.insert("\(key)=\(value)", at: insert)
        }
        return lines.joined(separator: newline) + newline
    }
}
