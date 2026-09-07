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
            let depots = try SteamPlanBuilder.selectedDepots(app, ownedApps: owned.appIDs)
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
            let servers = try await CDNClient.contentServers(cellID: cm.cellID)
            let total = payload.manifests.reduce(Int64(0)) { $0 + Int64($1.totalSize) }
            var completed: Int64 = 0
            for manifest in payload.manifests {
                try Task.checkCancellation()
                let before = completed
                var engine = DownloadEngine(cm: cm, appID: payload.app.appID, destination: directory)
                engine.onProgress = { update in progress(InstallProgress(bytesCompleted: before + Int64(update.bytesDone), bytesTotal: total, currentFile: update.file)) }
                try await engine.download(manifest: manifest, servers: servers)
                completed += Int64(manifest.totalSize)
            }
        }
    }
}
