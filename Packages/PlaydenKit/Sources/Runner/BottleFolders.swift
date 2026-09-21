import Foundation
import Darwin
import Domain

/// Called only after the template/game ownership receipt has been verified. XDG destinations
/// keep Windows shell folders inside this bottle, including after CrossOver's restore hook.
enum BottleFolders {
    static let directoryName = ".playden-folders"
    private static let names = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Templates"]
    private static let windowsNames = ["Desktop", "Documents", "Downloads", "Pictures", "Videos", "Movies", "Music", "Templates"]
    private static let variables = ["DESKTOP", "DOCUMENTS", "DOWNLOAD", "PICTURES", "VIDEOS", "MUSIC", "TEMPLATES"]
    static func bootstrap(at root: URL) throws -> URL {
        try makeDirectory(root)
        let folders = root.appendingPathComponent(directoryName)
        try makeDirectory(folders)
        for name in names { try makeDirectory(folders.appendingPathComponent(name)) }
        try write(configuration(for: root), to: folders.appendingPathComponent("user-dirs.dirs"))
        return folders
    }
    static func configure(_ bottle: URL, publishedAt destination: URL? = nil) throws {
        try physicalDirectory(bottle)
        let target = destination ?? bottle
        let folders = bottle.appendingPathComponent(directoryName)
        try makeDirectory(folders)
        for name in names { try makeDirectory(folders.appendingPathComponent(name)) }
        try write(configuration(for: target), to: folders.appendingPathComponent("user-dirs.dirs"))
        let file = bottle.appendingPathComponent("cxbottle.conf")
        try regularFile(file)
        let text = try String(contentsOf: file, encoding: .utf8)
        let replacements = ["XDG_CONFIG_HOME": "${WINEPREFIX}/" + directoryName, "CX_DIRECT_DESKTOP": "1"]
        var lines: [String] = [], inEnvironment = false, found = false
        func appendSettings() { for key in replacements.keys.sorted() { lines.append("\"\(key)\" = \"\(replacements[key]!)\"") } }
        for raw in (text.hasSuffix("\n") ? String(text.dropLast()) : text).components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if inEnvironment { appendSettings() }
                inEnvironment = trimmed == "[EnvironmentVariables]"
                if inEnvironment { found = true }
            }
            if inEnvironment, let equals = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if replacements[key] != nil { continue }
            }
            lines.append(raw)
        }
        if inEnvironment { appendSettings() }
        if !found { lines.append("[EnvironmentVariables]"); appendSettings() }
        try write(lines.joined(separator: "\n") + "\n", to: file)
        // Remove links themselves, never their targets. Old Wine defaults may still point at
        // personal Mac folders; SHGetFolderPath checks them before applying new XDG targets.
        let users = bottle.appendingPathComponent("drive_c/users")
        guard exists(users) else { return }
        try physicalDirectory(bottle.appendingPathComponent("drive_c")); try physicalDirectory(users)
        for user in try FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(user.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            for name in windowsNames {
                let folder = user.appendingPathComponent(name)
                try removeLink(folder)
                if name == "Desktop" {
                    try makeDirectory(folder)
                    for link in ["My Mac Desktop", "My Linux Desktop", "My Native Desktop", "My Android Downloads"] { try removeLink(folder.appendingPathComponent(link)) }
                }
            }
        }
    }
    static func verify(_ bottle: URL) throws {
        try physicalDirectory(bottle)
        let folders = bottle.appendingPathComponent(directoryName)
        try physicalDirectory(folders)
        for name in names { try physicalDirectory(folders.appendingPathComponent(name)) }
        let file = folders.appendingPathComponent("user-dirs.dirs")
        try regularFile(file)
        guard try String(contentsOf: file, encoding: .utf8) == configuration(for: bottle) else { throw failure() }
        let config = bottle.appendingPathComponent("cxbottle.conf")
        try regularFile(config)
        let text = try String(contentsOf: config, encoding: .utf8)
        guard text.contains("\"XDG_CONFIG_HOME\" = \"${WINEPREFIX}/\(directoryName)\""), text.contains("\"CX_DIRECT_DESKTOP\" = \"1\"") else { throw failure() }
        let users = bottle.appendingPathComponent("drive_c/users")
        if exists(users) {
            try physicalDirectory(bottle.appendingPathComponent("drive_c")); try physicalDirectory(users)
            for user in try FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil) {
                var info = stat()
                guard lstat(user.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                for name in windowsNames + ["Desktop/My Mac Desktop", "Desktop/My Linux Desktop", "Desktop/My Native Desktop", "Desktop/My Android Downloads"] {
                    let path = user.appendingPathComponent(name)
                    if exists(path), !path.resolvingSymlinksInPath().path.hasPrefix(bottle.resolvingSymlinksInPath().path + "/") { throw failure() }
                }
            }
        }
    }
    private static func configuration(for bottle: URL) -> String {
        zip(variables, names).map { variable, name in
            let path = bottle.appendingPathComponent(directoryName).appendingPathComponent(name).path
                .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "XDG_\(variable)_DIR=\"\(path)\"\n"
        }.joined()
    }
    private static func removeLink(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 { if errno == ENOENT { return }; throw failure() }
        if info.st_mode & S_IFMT == S_IFLNK, unlink(url.path) != 0 { throw failure() }
    }
    private static func makeDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw failure() }
        try physicalDirectory(url)
    }
    private static func physicalDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw failure() }
    }
    private static func regularFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw failure() }
    }
    private static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
    private static func write(_ text: String, to url: URL) throws {
        if exists(url) { try regularFile(url) }
        try Data(text.utf8).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.synchronize()
    }
    private static func failure() -> OperationFailure {
        .init(stage: "Game folders", reason: "The game's private Windows folders could not be prepared safely.", output: "A folder, configuration file or saved folder mapping is unavailable or points outside its owned location.")
    }
}
