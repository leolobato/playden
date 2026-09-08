import Foundation
import Domain
import SteamCore

/// Installation probe, read-only unless a temporary download root is explicitly supplied.
/// Reports stages and error codes, never credentials, account identifiers, response bodies,
/// depot keys or signed request URLs.
public enum SteamInstallDiagnostics {
    public static func inspect(appID: UInt32, downloadProbeRoot: URL? = nil, report: @escaping @Sendable (String) -> Void) async -> Bool {
        let cm = CMClient(depotKeyStore: MemoryDepotKeys())
        var stage = "Keychain"
        do {
            report("Checking saved sign-in")
            guard let saved = try KeychainCredentials().load() else {
                report("Keychain: no saved sign-in"); return false
            }
            stage = "Access token renewal"
            let credentials = try await LiveSteamBackend().renew(saved)
            report("Access token: usable")
            stage = "Steam connection"
            try await cm.connect()
            stage = "Steam logon"
            _ = try await cm.logOn(accountName: credentials.accountName, refreshToken: credentials.refreshToken)
            report("Steam logon: accepted")
            stage = "License list"
            try await cm.waitForLicenses()
            stage = "App metadata"
            let app = try await cm.appInfo(appID: appID)
            for launch in app.launches {
                report(DiagnosticRedactor.redact("Launch \(launch.id): \(launch.executable); branch \(launch.betaKey ?? "public"); DLC \(launch.requiredDLC ?? 0)"))
            }
            stage = "Ownership"
            let owned = try await cm.ownedEntitlements()
            guard owned.appIDs.contains(appID) else {
                report("Ownership: selected game is not owned"); await cm.disconnect(); return false
            }
            report("Ownership: verified")
            stage = "Depot selection"
            for depot in app.depots where depot.isWindows && depot.isEnglishOrAll && !depot.isSharedInstall {
                report("Depot \(depot.id): \(owned.depotIDs.contains(depot.id) ? "entitled" : "not entitled")")
            }
            let depots = try SteamPlanBuilder.selectedDepots(app, ownedApps: owned.appIDs, ownedDepots: owned.depotIDs)
            report("Selected \(depots.count) depots")
            stage = "Content server list"
            let servers = try await CDNClient.contentServers(cellID: cm.cellID)
            var manifests: [DepotManifest] = []
            for depot in depots {
                stage = "Depot \(depot.id) key"
                let key = try await cm.depotKey(appID: appID, depotID: depot.id)
                guard let gid = depot.manifestGID else { throw SteamError.protocolError("missing manifest") }
                stage = "Depot \(depot.id) manifest authorization"
                let code = try await cm.manifestRequestCode(appID: appID, depotID: depot.id, manifestGID: gid)
                stage = "Depot \(depot.id) manifest download"
                guard let server = servers.first else { throw SteamError.protocolError("missing content server") }
                manifests.append(try await CDNClient.fetchManifest(server: server, depotID: depot.id, gid: gid, requestCode: code, depotKey: key))
                report("Depot \(depot.id): manifest verified")
            }
            stage = "Install plan"
            let plan = try SteamPlanBuilder.build(game: .init(id: .init(source: "steam", value: String(appID)), title: "Diagnostic"),
                app: app, manifests: manifests, ownedApps: owned.appIDs, ownedDepots: owned.depotIDs)
            report("Install plan ready: \(plan.estimate.downloadBytes) download bytes; no game files written")
            if let downloadProbeRoot {
                stage = "Chunk download and disk write probe"
                try await probeDownload(cm: cm, appID: appID, manifests: manifests, servers: servers, root: downloadProbeRoot, report: report)
            }
            await cm.disconnect()
            return true
        } catch {
            report("\(stage): \(code(for: error))")
            await cm.disconnect()
            return false
        }
    }

    /// Opt-in bounded probe through the real downloader. Never uses an installation's folder.
    private static func probeDownload(cm: CMClient, appID: UInt32, manifests: [DepotManifest], servers: [ContentServer],
                                      root: URL, report: @escaping @Sendable (String) -> Void) async throws {
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              let manifest = manifests.first(where: { $0.files.contains { !$0.isDirectory && !$0.isSymlink && !$0.chunks.isEmpty } }),
              let file = manifest.files.first(where: { !$0.isDirectory && !$0.isSymlink && !$0.chunks.isEmpty }) else {
            throw SteamPlanBuilder.failure("Probe", "Choose an existing folder for the download probe.")
        }
        var chunks: [DepotManifest.Chunk] = [], size: UInt64 = 0
        for chunk in file.chunks.sorted(by: { $0.offset < $1.offset }).prefix(8) {
            guard size + UInt64(chunk.uncompressedSize) <= 8 * 1024 * 1024 else { break }
            chunks.append(chunk); size += UInt64(chunk.uncompressedSize)
        }
        guard !chunks.isEmpty else { throw SteamPlanBuilder.failure("Probe", "No chunk fits the 8 MiB probe limit.") }
        let directory = root.appendingPathComponent(".big-screen-download-probe-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = DepotManifest(depotID: manifest.depotID, gid: manifest.gid,
            files: [.init(path: "probe.bin", size: size, chunks: chunks)], totalSize: size)
        var engine = DownloadEngine(cm: cm, appID: appID, destination: directory)
        engine.onProgress = { report("Probe written: \($0.bytesDone)/\($0.bytesTotal) bytes") }
        try await engine.download(manifest: probe, servers: servers)
        guard try ResumableDepotDownload(destination: directory).invalidFiles(in: probe).isEmpty else {
            throw SteamPlanBuilder.failure("Probe", "Downloaded probe failed verification.")
        }
        report("Download probe passed; \(size) bytes verified on the selected drive; temporary files removed on exit")
    }

    static func code(for error: Error) -> String {
        if let failure = error as? OperationFailure { return DiagnosticRedactor.redact(failure.reason) }
        if let keychain = error as? KeychainFailure { return "Keychain OSStatus \(keychain.status)" }
        if let network = error as? URLError { return "Network error \(network.errorCode)" }
        if let steam = error as? SteamError {
            switch steam {
            case .http(let status, _): return "HTTP \(status)"
            case .eresult(let result, _): return "Steam EResult \(result.rawValue)"
            case .authSessionExpired: return "Steam session ended"
            case .authFailed: return "Steam rejected authentication"
            case .notLoggedIn: return "No saved sign-in"
            case .protocolError: return "Unexpected Steam response"
            case .crypto: return "Content decryption failed"
            case .download: return "Content verification failed"
            case .prepare: return "Preparation failed"
            }
        }
        return error is CancellationError ? "Cancelled" : "Request failed"
    }
}
