import Foundation
import Darwin
import Domain

/// The catalog keeps its stable ownership identity; only CrossOver's physical directory label
/// changes. Resolve both old and titled directories, and fail closed on ambiguous identities.
enum CrossOverBottlePresentation {
    static func title(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._()-"))
        let clean = String(String.UnicodeScalarView(title.unicodeScalars.map { allowed.contains($0) ? $0 : " " }))
        var result = ""
        for character in clean.split(whereSeparator: \.isWhitespace).joined(separator: " ") {
            guard result.utf8.count + String(character).utf8.count <= 90 else { break }
            result.append(character)
        }
        return result
    }
    static func name(title: String, bottle: GameBottle) -> String {
        let label = self.title(title)
        return label.isEmpty ? bottle.name : "\(label) (\(bottle.name))"
    }
    static func directory(for bottle: GameBottle, under root: URL) throws -> URL {
        guard bottle.name == CrossOverGameBottles.name(for: bottle.gameID) else { throw failure() }
        func matches(_ name: String) -> Bool {
            name == bottle.name || (name.hasSuffix(" (\(bottle.name))") && !name.contains("/") && !name.contains("\0"))
        }
        let pending = root.appendingPathComponent(".playden-removing-\(bottle.ownershipToken.uuidString).json")
        if FileManager.default.fileExists(atPath: pending.path) {
            struct Receipt: Decodable { let owner: GameBottle; let path: String }
            guard try pending.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw failure() }
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: pending))
            let directory = URL(fileURLWithPath: receipt.path).standardizedFileURL
            guard receipt.owner == bottle, directory.deletingLastPathComponent().path == root.standardizedFileURL.path,
                  matches(directory.lastPathComponent) else { throw failure() }
            return directory
        }
        var info = stat()
        if lstat(root.path, &info) != 0 {
            guard errno == ENOENT else { throw failure() }
            return root.appendingPathComponent(bottle.name)
        }
        let candidates = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { matches($0.lastPathComponent) }
        guard candidates.count <= 1 else { throw failure() }
        return root.appendingPathComponent(candidates.first?.lastPathComponent ?? bottle.name)
    }
    static func script(application: URL, bottle: URL, directory: URL, spec: LaunchSpec) throws -> String {
        let arguments = try CrossOverRunner.arguments(spec, bottle: bottle, directory: directory)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let environment = spec.environment.keys.sorted().map { "\($0)=\(spec.environment[$0]!)" }
        let command = ["/usr/bin/env"] + environment + [application.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/cxstart").path] + arguments
        return "#!/bin/sh\nexec " + command.map(quote).joined(separator: " ") + "\n"
    }
    private static func failure() -> OperationFailure {
        .init(stage: "Game runtime", reason: "The game's bottle location is ambiguous or invalid. Its files have been kept.", output: "")
    }
}
