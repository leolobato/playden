import Foundation
import Domain
import SteamCore

extension SteamSource {
    public func downloadSizeAccountKey() async throws -> String? { try await account.downloadSizeAccountKey() }
    public func downloadSize(for game: SourceGameRecord) async throws -> DownloadSizeEstimate? {
        guard game.id.source == id, let appID = UInt32(game.id.value), let key = try await downloadSizeAccountKey() else { return nil }
        let result = try await account.withCM(purpose: "download-size", appID: appID) { cm in
            let app = try await cm.appInfo(appID: appID)
            let owned = try await cm.ownedEntitlements()
            guard owned.appIDs.contains(appID) else { throw SourceFailure.accessDenied }
            return try Self.downloadSize(app: app, owned: owned, accountKey: key)
        }
        guard try await downloadSizeAccountKey() == key else { throw CancellationError() }
        return result
    }
    static func downloadSize(app: AppInfo, owned: SteamEntitlements, accountKey: String) throws -> DownloadSizeEstimate {
        let depots = try SteamPlanBuilder.selectedDepots(app, ownedApps: owned.appIDs, ownedDepots: owned.depotIDs)
        var total: UInt64 = 0
        var known = true
        for depot in depots {
            // PICS uses zero when compressed-size metadata is absent. Don't display a
            // partial total or substitute the uncompressed disk requirement.
            if depot.downloadSize == 0 { known = false }
            let sum = total.addingReportingOverflow(depot.downloadSize)
            guard !sum.overflow, sum.partialValue <= UInt64(Int64.max) else { throw SourceFailure.malformedResponse }
            total = sum.partialValue
        }
        return .init(accountKey: accountKey, bytes: known ? Int64(total) : nil,
            manifestIDs: Dictionary(uniqueKeysWithValues: depots.map { (String($0.id), String($0.manifestGID!)) }))
    }
}
