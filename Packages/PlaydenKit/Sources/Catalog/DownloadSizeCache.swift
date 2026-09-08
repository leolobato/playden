import Foundation
import Domain
import GRDB

extension CatalogStore {
    public func downloadSize(for game: GameID, accountKey: String) throws -> DownloadSizeEstimate? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT payload, invalidated FROM download_sizes WHERE source = ? AND game = ? AND account = ?",
                arguments: [game.source, game.value, accountKey]) else { return nil }
            var value = try JSONDecoder().decode(DownloadSizeEstimate.self, from: row["payload"])
            if row["invalidated"] as Bool { value.checkedAt = .distantPast }
            return value
        }
    }
    public func saveDownloadSize(_ estimate: DownloadSizeEstimate, for game: GameID) throws {
        try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM source_games WHERE source = ? AND game = ?)", arguments: [game.source, game.value]) == true else { return }
            var value = estimate
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM download_sizes WHERE source = ? AND game = ? AND account = ?",
                arguments: [game.source, game.value, estimate.accountKey]) {
                let old = try JSONDecoder().decode(DownloadSizeEstimate.self, from: data)
                guard estimate.checkedAt >= old.checkedAt else { return }
                if old.precise && !estimate.precise && old.manifestIDs == estimate.manifestIDs {
                    value = old; value.checkedAt = estimate.checkedAt
                }
            }
            try db.execute(sql: "INSERT INTO download_sizes (source, game, account, payload, invalidated) VALUES (?, ?, ?, ?, 0) ON CONFLICT(source, game, account) DO UPDATE SET payload = excluded.payload, invalidated = 0",
                arguments: [game.source, game.value, value.accountKey, try JSONEncoder().encode(value)])
        }
    }
    public func invalidateDownloadSizes(source: String) throws {
        try database.write { db in try db.execute(sql: "UPDATE download_sizes SET invalidated = 1 WHERE source = ?", arguments: [source]) }
    }
}
