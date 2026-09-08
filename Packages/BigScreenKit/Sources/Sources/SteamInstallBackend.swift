import Foundation
import Domain
import SteamCore

struct ResolvedSteamContent: Sendable {
    let app: AppInfo
    let manifests: [DepotManifest]
    let entitlements: SteamEntitlements
}
protocol SteamInstallBackend: Sendable {
    func resolve(appID: UInt32) async throws -> ResolvedSteamContent
    func download(_ payload: SteamInstallPayload, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws
}
struct LiveSteamInstallBackend: SteamInstallBackend {
    let account: SteamAccount
    func resolve(appID: UInt32) async throws -> ResolvedSteamContent {
        try await account.withCM { cm in
            let app = try await cm.appInfo(appID: appID)
            let owned = try await cm.ownedEntitlements()
            guard owned.appIDs.contains(appID) else { throw SteamPlanBuilder.failure("Resolve", "This account does not own the selected game.") }
            let depots = try SteamPlanBuilder.selectedDepots(app, ownedApps: owned.appIDs, ownedDepots: owned.depotIDs)
            let servers = try await CDNClient.contentServers(cellID: cm.cellID)
            // Manifest resolution does not create or write a destination directory.
            let engine = DownloadEngine(cm: cm, appID: appID, destination: URL(fileURLWithPath: "/"))
            var manifests: [DepotManifest] = []
            for depot in depots {
                try Task.checkCancellation()
                manifests.append(try await engine.manifest(depot: depot, servers: servers))
            }
            return ResolvedSteamContent(app: app, manifests: manifests, entitlements: owned)
        }
    }
    func download(_ payload: SteamInstallPayload, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await account.withCM { cm in
            let owned = try await cm.ownedEntitlements()
            guard owned.appIDs.contains(payload.app.appID), Set(payload.ownedDLC).isSubset(of: owned.appIDs) else {
                throw SteamPlanBuilder.failure("Download", "The signed-in account no longer owns all content in this install plan.")
            }
            guard Set(payload.manifests.map(\.depotID)).isSubset(of: owned.depotIDs) else {
                throw SteamPlanBuilder.failure("Download", "This account no longer has access to all depots in the saved install plan. Resolve the installation again with an account that owns this edition.")
            }
            let servers = try await CDNClient.contentServers(cellID: cm.cellID)
            let total = payload.manifests.reduce(Int64(0)) { $0 + Int64($1.totalSize) }
            let transfers = SteamTransferProgress(total: total, report: progress)
            var completed: Int64 = 0
            for manifest in payload.manifests {
                try Task.checkCancellation()
                let before = completed
                var engine = DownloadEngine(cm: cm, appID: payload.app.appID, destination: directory)
                engine.onTransfer = { transfers.received($0) }
                engine.onProgress = { update in
                    transfers.assembled(depot: update.depotID, completed: before + Int64(update.bytesDone),
                        fresh: update.bytesWritten.map(Int64.init), file: update.file,
                        verification: update.verification.map {
                            .init(file: update.file, bytesChecked: Int64($0.bytesChecked), bytesTotal: Int64($0.bytesTotal))
                        })
                }
                try await engine.download(manifest: manifest, servers: servers)
                completed += Int64(manifest.totalSize)
            }
        }
    }
}
