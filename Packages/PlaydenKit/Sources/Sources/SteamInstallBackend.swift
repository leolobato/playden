import Foundation
import Domain
import SteamCore

struct ResolvedSteamContent: Sendable {
    let app: AppInfo
    let manifests: [DepotManifest]
    let entitlements: SteamEntitlements
}
protocol SteamInstallBackend: Sendable {
    func resolve(appID: UInt32, platform: GamePlatform) async throws -> ResolvedSteamContent
    func download(_ payload: SteamInstallPayload, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws
    func repair(_ payload: SteamInstallPayload, using repair: SteamRepairDownload, to directory: URL,
                progress: @escaping @Sendable (InstallProgress) -> Void) async throws
}
extension SteamInstallBackend {
    // Older conformers receive the authoritative mapped payload, so their normal download and
    // cleanup semantics remain sound. The production backend uses the forced subset below.
    func repair(_ payload: SteamInstallPayload, using repair: SteamRepairDownload, to directory: URL,
                progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await download(payload, to: directory, progress: progress)
    }
}
struct SteamRepairDownload: Sendable {
    let invalidPaths: Set<String>
    let receiptExcludedPaths: Set<String>
    let receiptManifests: [DepotManifest]

    func subset(of manifest: DepotManifest) throws -> DepotManifest {
        let files = try manifest.files.filter { invalidPaths.contains(try SteamPlanBuilder.relativePath($0.path)) }
        return DepotManifest(depotID: manifest.depotID, gid: manifest.gid, files: files, totalSize: files.reduce(0) { $0 + $1.size })
    }
    func downloader(for manifest: DepotManifest, at directory: URL, diagnostics: SteamPerformanceDiagnostics?) -> ResumableDepotDownload {
        var download = ResumableDepotDownload(destination: directory, diagnostics: diagnostics)
        download.forceDownloadPaths = invalidPaths
        download.receiptExcludedPaths = receiptExcludedPaths
        download.receiptManifest = receiptManifests.first { $0.depotID == manifest.depotID && $0.gid == manifest.gid }
        download.cleanupCompletedDepot = false
        return download
    }
}
struct LiveSteamInstallBackend: SteamInstallBackend {
    let account: SteamAccount
    var diagnostics: SteamPerformanceDiagnostics? = nil
    func resolve(appID: UInt32, platform: GamePlatform) async throws -> ResolvedSteamContent {
        try await account.withCM(purpose: "resolve", appID: appID) { cm in
            let app = try await cm.appInfo(appID: appID)
            let owned = try await cm.ownedEntitlements()
            guard owned.appIDs.contains(appID) else { throw SteamPlanBuilder.failure("Resolve", "This account does not own the selected game.") }
            let depots = try SteamPlanBuilder.selectedDepots(app, ownedApps: owned.appIDs, ownedDepots: owned.depotIDs, platform: platform)
            let servers = try await CDNClient.contentServers(cellID: cm.cellID)
            // Manifest resolution does not create or write a destination directory.
            let transport = URLSessionCDNTransport()
            let engine = DownloadEngine(cm: cm, appID: appID, destination: URL(fileURLWithPath: "/"), transport: transport)
            var manifests: [DepotManifest] = []
            for depot in depots {
                try Task.checkCancellation()
                manifests.append(try await engine.manifest(depot: depot, servers: servers))
            }
            return ResolvedSteamContent(app: app, manifests: manifests, entitlements: owned)
        }
    }
    func download(_ payload: SteamInstallPayload, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await download(payload, repair: nil, to: directory, progress: progress)
    }
    func repair(_ payload: SteamInstallPayload, using repair: SteamRepairDownload, to directory: URL,
                progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await download(payload, repair: repair, to: directory, progress: progress)
    }
    private func download(_ payload: SteamInstallPayload, repair: SteamRepairDownload?, to directory: URL,
                          progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        let manifests = try repair.map { repair in try payload.manifests.map { try repair.subset(of: $0) }.filter { !$0.files.isEmpty } } ?? payload.manifests
        try await account.withCM(purpose: "download", appID: payload.app.appID) { cm in
            let owned = try await cm.ownedEntitlements()
            guard owned.appIDs.contains(payload.app.appID), Set(payload.ownedDLC).isSubset(of: owned.appIDs) else {
                throw SteamPlanBuilder.failure("Download", "The signed-in account no longer owns all content in this install plan.")
            }
            guard Set(payload.manifests.map(\.depotID)).isSubset(of: owned.depotIDs) else {
                throw SteamPlanBuilder.failure("Download", "This account no longer has access to all depots in the saved install plan. Resolve the installation again with an account that owns this edition.")
            }
            let servers = try await CDNClient.contentServers(cellID: cm.cellID)
            let transport = URLSessionCDNTransport()
            let preparation = DownloadEngine(cm: cm, appID: payload.app.appID, destination: directory, diagnostics: diagnostics, transport: transport)
            try await preparation.prepare(manifests: manifests)
            // Entitlements and depot keys were resolved above; transfers only use the CDN.
            // The CM connection is shared with other operations, so it must stay connected.
            let total = manifests.reduce(Int64(0)) { $0 + Int64($1.totalSize) }
            let transfers = SteamTransferProgress(total: total, report: { value in
                diagnostics.measure(.progressCallback) { progress(value) }
            })
            var completed: Int64 = 0
            for manifest in manifests {
                try Task.checkCancellation()
                let before = completed
                var engine = DownloadEngine(cm: cm, appID: payload.app.appID, destination: directory, diagnostics: diagnostics, transport: transport)
                engine.onTransfer = { transfers.received($0) }
                engine.onProgress = { update in
                    transfers.assembled(depot: update.depotID, completed: before + Int64(update.bytesDone),
                        fresh: update.bytesWritten.map(Int64.init), file: update.file,
                        verification: update.verification.map {
                            .init(file: update.file, bytesChecked: Int64($0.bytesChecked), bytesTotal: Int64($0.bytesTotal))
                        })
                }
                try await engine.download(manifest: manifest, servers: servers,
                    forceDownloadPaths: repair?.invalidPaths ?? [], receiptExcludedPaths: repair?.receiptExcludedPaths ?? [],
                    receiptManifest: repair?.receiptManifests.first { $0.depotID == manifest.depotID && $0.gid == manifest.gid },
                    cleanupCompletedDepot: repair == nil)
                completed += Int64(manifest.totalSize)
            }
        }
    }
}
