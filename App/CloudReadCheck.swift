#if DEBUG
import Foundation
import CryptoKit
import Domain
import Sources

/// Explicit developer check, using the signed app's existing Keychain access. Reads remote data
/// only; it never writes a game save, changes a Cloud revision, or marks the game synchronized.
enum CloudReadCheck {
    struct Report: Encodable {
        let gameID: GameID
        let revision: UInt64
        let presentFiles: Int
        let deletedFiles: Int
        let forgottenFiles: Int
        let downloads: [Download]
        let outcome: String
    }
    struct Download: Encodable {
        let name: String
        let bytes: Int
        let sha256: String
        let artifact: String
    }
    static func run(game: String) async {
        let gameID = GameID(source: "steam", value: game)
        let root = AppPaths.supportRoot().appendingPathComponent("Diagnostics")
        let directory = root.appendingPathComponent("cloud-read-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let cloud = SteamCloudReader(account: SteamAccount())
            let list = try await cloud.files(for: gameID)
            var downloads: [Download] = []
            for (index, file) in list.files.filter({ $0.state == .present }).enumerated() {
                let data = try await cloud.download(file, from: list)
                let name = "download-\(index).bin"
                try data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(name).path)
                downloads.append(Download(name: DiagnosticRedactor.redact(file.name), bytes: data.count,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), artifact: name))
            }
            let after = try await cloud.files(for: gameID)
            guard after == list else { throw OperationFailure(stage: "Steam Cloud", reason: "The remote save list changed during the check. Retry to obtain a consistent result.", output: "") }
            let report = Report(gameID: gameID, revision: list.revision, presentFiles: downloads.count,
                deletedFiles: list.files.filter { $0.state == .deleted }.count,
                forgottenFiles: list.files.filter { $0.state == .forgotten }.count,
                downloads: downloads, outcome: "All present files downloaded and checksum verified; remote revision unchanged")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            // No raw HTTP errors, signed URLs, account identifiers or server bodies in diagnostics.
            let reason = (error as? OperationFailure)?.reason ?? "Cloud read check failed or was cancelled."
            try? Data(reason.utf8).write(to: directory.appendingPathComponent("failure.txt"), options: .atomic)
        }
    }
}
#endif
