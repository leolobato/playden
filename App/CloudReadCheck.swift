#if DEBUG
import Foundation
import CryptoKit
import Domain
import Sources
import Catalog
import Installs
import Runner

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
        let mappedFiles: Int
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
            var payloads: [CloudUpload] = []
            for (index, file) in list.files.filter({ $0.state == .present }).enumerated() {
                let data = try await cloud.download(file, from: list)
                payloads.append(.init(file: file, data: data))
                let name = "download-\(index).bin"
                try data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(name).path)
                downloads.append(Download(name: DiagnosticRedactor.redact(file.name), bytes: data.count,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), artifact: name))
            }
            let after = try await cloud.files(for: gameID)
            guard after == list else { throw OperationFailure(stage: "Steam Cloud", reason: "The remote save list changed during the check. Retry to obtain a consistent result.", output: "") }
            let catalog = try CatalogStore(path: AppPaths.supportRoot().appendingPathComponent("catalog.sqlite").path)
            guard let installed = try catalog.snapshot().entries.first(where: { $0.id == gameID })?.installation,
                  let plan = installed.plan else {
                throw OperationFailure(stage: "Steam Cloud", reason: "Install the game before checking its save mapping.", output: "")
            }
            var mapping = try SteamInstaller(game: installed.game, account: SteamAccount()).saveMapping(plan)
            if mapping.requiresSteamAccountResolution {
                let bottle = GameBottle(gameID: installed.gameID, name: installed.bottleID,
                    ownershipToken: installed.ownershipToken, templateVersion: installed.templateVersion)
                let root = try await CrossOverGameBottles().ownedDirectory(bottle)
                let localID = try await SaveStore().steamLocalAccountID(roots: [.bottle: root], createIfMissing: false)
                mapping = try await cloud.resolveAccountPaths(mapping, localSteamID: localID)
                guard mapping.boundAccountKey == list.accountKey else {
                    throw OperationFailure(stage: "Steam Cloud", reason: "The account changed during the check.", output: "")
                }
            }
            // Exercise the real path resolver and immutable staging store in Diagnostics only.
            let staged = try await SaveStore(root: directory.appendingPathComponent("staged")).stageCloud(
                list, installationID: installed.id, mapping: mapping, downloads: payloads)
            let report = Report(gameID: gameID, revision: list.revision, presentFiles: downloads.count,
                deletedFiles: list.files.filter { $0.state == .deleted }.count,
                forgottenFiles: list.files.filter { $0.state == .forgotten }.count,
                downloads: downloads, mappedFiles: staged.files.count,
                outcome: "All present files downloaded, mapped and checksum verified; remote revision unchanged")
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
