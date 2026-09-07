import Foundation
import Domain
import GRDB

public enum CatalogError: Error, Equatable {
    case sourceMismatch, duplicateGame, invalidCollectionName, duplicateCollectionName, identityMismatch, invalidSession
}

/// The sole writer of durable application state. GRDB serializes writes and commits each operation
/// atomically; callers never maintain a second writable JSON copy beside the database.
public final class CatalogStore: Sendable {
    private let database: DatabaseQueue
    public init(path: String = ":memory:") throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        database = try DatabaseQueue(path: path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_catalog") { db in
            for table in ["source_games", "game_edits"] {
                try db.create(table: table) { t in
                    t.column("source", .text).notNull()
                    t.column("game", .text).notNull()
                    t.column("payload", .blob).notNull()
                    t.primaryKey(["source", "game"])
                }
            }
            try db.create(table: "source_sync") { t in
                t.primaryKey("source", .text)
                t.column("syncedAt", .datetime).notNull()
            }
            try db.create(table: "collections") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("normalizedName", .text).notNull().unique()
                t.column("pinned", .boolean).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(table: "collection_members") { t in
                t.column("collectionID", .text).notNull().references("collections", onDelete: .cascade)
                // No foreign key to source_games: membership survives refresh/logout.
                t.column("source", .text).notNull()
                t.column("game", .text).notNull()
                t.primaryKey(["collectionID", "source", "game"])
            }
            try db.create(table: "preferences") { t in
                t.primaryKey("id", .integer)
                t.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("v2_operations") { db in
            for table in ["installations", "jobs", "sessions"] {
                try db.create(table: table) { t in
                    t.primaryKey("id", .text)
                    t.column("source", .text).notNull()
                    t.column("game", .text).notNull()
                    t.column("payload", .blob).notNull()
                    if table == "installations" { t.uniqueKey(["source", "game"]) }
                }
                try db.create(index: "\(table)_game", on: table, columns: ["source", "game"])
            }
        }
        try migrator.migrate(database)
    }

    /// A complete successful owned-library response replaces only this source's cache. A failed
    /// network fetch must not call this method. Lightweight sync preserves enriched metadata.
    public func replaceSourceCatalog(source: String, games: [SourceGameRecord], syncedAt: Date = .now) throws {
        guard games.allSatisfy({ $0.id.source == source }) else { throw CatalogError.sourceMismatch }
        guard Set(games.map(\.id)).count == games.count else { throw CatalogError.duplicateGame }
        try database.write { db in
            let old: [SourceGameRecord] = try Self.values(db, table: "source_games", whereSQL: "source = ?", arguments: [source])
            let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            try db.execute(sql: "DELETE FROM source_games WHERE source = ?", arguments: [source])
            for var record in games {
                if let prior = previous[record.id] {
                    record.firstObservedAt = prior.firstObservedAt
                    if record.metadataUpdatedAt == nil { Self.copyMetadata(from: prior, to: &record) }
                }
                try Self.putGame(db, table: "source_games", id: record.id, value: record)
            }
            try db.execute(sql: "INSERT INTO source_sync (source, syncedAt) VALUES (?, ?) ON CONFLICT(source) DO UPDATE SET syncedAt = excluded.syncedAt", arguments: [source, syncedAt])
        }
    }

    /// Ignores late metadata when the game/source was removed while a request was in flight.
    @discardableResult public func updateMetadata(_ metadata: SourceGameRecord) throws -> Bool {
        try database.write { db in
            let records: [SourceGameRecord] = try Self.values(db, table: "source_games", whereSQL: "source = ? AND game = ?", arguments: [metadata.id.source, metadata.id.value])
            guard var record = records.first else { return false }
            if let current = record.metadataUpdatedAt, let incoming = metadata.metadataUpdatedAt, incoming < current { return false }
            Self.copyMetadata(from: metadata, to: &record)
            try Self.putGame(db, table: "source_games", id: record.id, value: record)
            return true
        }
    }
    public func clearSourceCatalog(_ source: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM source_games WHERE source = ?", arguments: [source])
            try db.execute(sql: "DELETE FROM source_sync WHERE source = ?", arguments: [source])
        }
    }
    public func lastSync(for source: String) throws -> Date? {
        try database.read { try Date.fetchOne($0, sql: "SELECT syncedAt FROM source_sync WHERE source = ?", arguments: [source]) }
    }
    public func saveEdits(_ edits: GameEdits, for id: GameID) throws {
        try database.write { try Self.putGame($0, table: "game_edits", id: id, value: edits) }
    }
    public func preferences() throws -> LibraryPreferences {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM preferences WHERE id = 1")
                .map { try Self.decode(LibraryPreferences.self, $0) } ?? LibraryPreferences()
        }
    }
    public func savePreferences(_ preferences: LibraryPreferences) throws {
        try database.write { try Self.putPreferences($0, preferences) }
    }
    public func saveCollections(_ collections: [GameCollection]) throws {
        try database.write { try Self.putCollections($0, collections) }
    }
    /// Used for a single UI edit that can change membership, selection and a game together.
    public func saveLibraryState(edits: [GameID: GameEdits], collections: [GameCollection], preferences: LibraryPreferences) throws {
        try database.write { db in
            for (id, value) in edits { try Self.putGame(db, table: "game_edits", id: id, value: value) }
            try Self.putCollections(db, collections)
            try Self.putPreferences(db, preferences)
        }
    }
    public func snapshot() throws -> CatalogSnapshot {
        try database.read { db in
            let sources: [SourceGameRecord] = try Self.values(db, table: "source_games")
            let installs: [InstallationRecord] = try Self.values(db, table: "installations")
            let sessions: [PlaySessionRecord] = try Self.values(db, table: "sessions")
            let editRows = try Row.fetchAll(db, sql: "SELECT source, game, payload FROM game_edits")
            let edits = try Dictionary(uniqueKeysWithValues: editRows.map { row in
                (GameID(source: row["source"], value: row["game"]), try Self.decode(GameEdits.self, row["payload"]))
            })
            var records = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
            for install in installs where records[install.gameID] == nil { records[install.gameID] = install.game }
            let installsByGame = Dictionary(uniqueKeysWithValues: installs.map { ($0.gameID, $0) })
            let sessionsByGame = Dictionary(grouping: sessions, by: \.gameID)
            let entries = records.values.map { source -> CatalogEntry in
                let history = sessionsByGame[source.id, default: []]
                return CatalogEntry(source: source, edits: edits[source.id] ?? GameEdits(), installation: installsByGame[source.id],
                    localPlaytimeSeconds: history.reduce(0) { $0 + $1.playedSeconds }, lastSession: history.max { $0.startedAt < $1.startedAt })
            }.sorted { $0.source.title.localizedStandardCompare($1.source.title) == .orderedAscending }
            let preferences = try Data.fetchOne(db, sql: "SELECT payload FROM preferences WHERE id = 1").map { try Self.decode(LibraryPreferences.self, $0) } ?? LibraryPreferences()
            let memberships = try Row.fetchAll(db, sql: "SELECT collectionID, source, game FROM collection_members")
            let collections = try Row.fetchAll(db, sql: "SELECT * FROM collections ORDER BY position, id").map { row in
                let id: String = row["id"]
                guard let uuid = UUID(uuidString: id) else { throw CatalogError.identityMismatch }
                let members = memberships.filter { ($0["collectionID"] as String) == id }.map { GameID(source: $0["source"], value: $0["game"]) }
                return GameCollection(id: uuid, name: row["name"], gameIDs: Set(members), isPinned: row["pinned"])
            }
            return CatalogSnapshot(entries: entries, collections: collections, preferences: preferences)
        }
    }
    public func saveInstallation(_ installation: InstallationRecord) throws {
        guard installation.gameID == installation.game.id else { throw CatalogError.identityMismatch }
        try database.write { try Self.putOperation($0, table: "installations", id: installation.id, gameID: installation.gameID, value: installation) }
    }
    /// Database bookkeeping only. The install service must verify filesystem removal before calling.
    public func removeInstallation(id: UUID) throws {
        try database.write { try $0.execute(sql: "DELETE FROM installations WHERE id = ?", arguments: [id.uuidString]) }
    }
    public func saveJob(_ job: JobRecord) throws {
        try database.write { try Self.putOperation($0, table: "jobs", id: job.id, gameID: job.gameID, value: job) }
    }
    public func saveJobs(_ jobs: [JobRecord]) throws {
        try database.write { db in
            for job in jobs { try Self.putOperation(db, table: "jobs", id: job.id, gameID: job.gameID, value: job) }
        }
    }
    /// Claim maintenance and block new play sessions in the same transaction. Session creation
    /// checks the same installation flag, closing the race between the queue and session actors.
    public func enqueueRepair(_ job: JobRecord) throws {
        guard job.kind == .repair, let original = job.originalInstallation else { throw CatalogError.identityMismatch }
        try database.write { db in
            let installs: [InstallationRecord] = try Self.values(db, table: "installations")
            guard var installed = installs.first(where: { $0.id == original.id }), installed == original,
                  installed.gameID == job.gameID, installed.ownershipToken == job.ownershipToken else { throw CatalogError.identityMismatch }
            let sessions: [PlaySessionRecord] = try Self.values(db, table: "sessions")
            let jobs: [JobRecord] = try Self.values(db, table: "jobs")
            guard !sessions.contains(where: { $0.gameID == job.gameID && $0.endedAt == nil }) else {
                throw OperationFailure(stage: "Verify files", reason: "Quit this game before verifying its files.", output: "")
            }
            guard !jobs.contains(where: { $0.gameID == job.gameID && ![.completed, .cancelled].contains($0.state) }) else {
                throw OperationFailure(stage: "Verify files", reason: "This game already has an unfinished job. Resume or retry it in Downloads.", output: "")
            }
            installed.needsRepair = true
            try Self.putOperation(db, table: "installations", id: installed.id, gameID: installed.gameID, value: installed)
            try Self.putOperation(db, table: "jobs", id: job.id, gameID: job.gameID, value: job)
        }
    }
    public func jobs() throws -> [JobRecord] {
        try database.read { db in
            let jobs: [JobRecord] = try Self.values(db, table: "jobs")
            return jobs.sorted { $0.queuePosition == $1.queuePosition ? $0.createdAt < $1.createdAt : $0.queuePosition < $1.queuePosition }
        }
    }
    /// The installed record and completed job must become visible in the same transaction.
    public func commitInstallation(_ installation: InstallationRecord, completing job: JobRecord) throws {
        guard installation.gameID == job.gameID, installation.gameID == installation.game.id,
              job.state == .completed, job.stage == .finished else { throw CatalogError.identityMismatch }
        try database.write { db in
            try Self.putOperation(db, table: "installations", id: installation.id, gameID: installation.gameID, value: installation)
            try Self.putOperation(db, table: "jobs", id: job.id, gameID: job.gameID, value: job)
        }
    }
    /// One row per session ID: repeated checkpoints/finalization never double-count playtime.
    public func saveSession(_ session: PlaySessionRecord) throws {
        guard session.playedSeconds >= 0, session.lastCheckpointAt >= session.startedAt,
              session.endedAt == nil || session.endedAt! >= session.startedAt,
              (session.endedAt == nil) == (session.outcome == nil) else { throw CatalogError.invalidSession }
        try database.write { db in
            let existing: [PlaySessionRecord] = try Self.values(db, table: "sessions", whereSQL: "id = ?", arguments: [session.id.uuidString])
            if let old = existing.first {
                guard old.gameID == session.gameID, old.startedAt == session.startedAt, old.bottleID == session.bottleID else { throw CatalogError.identityMismatch }
                // A late checkpoint must not overwrite a newer/final session.
                if old.endedAt != nil || old.lastCheckpointAt > session.lastCheckpointAt || old.playedSeconds > session.playedSeconds { return }
            } else if session.endedAt == nil {
                let installs: [InstallationRecord] = try Self.values(db, table: "installations")
                if installs.contains(where: { $0.gameID == session.gameID && $0.needsRepair == true }) {
                    throw OperationFailure(stage: "Launch game", reason: "Verify this game's files before playing. Resume or retry verification in Downloads.", output: "")
                }
            }
            try Self.putOperation(db, table: "sessions", id: session.id, gameID: session.gameID, value: session)
        }
    }
    public func unfinishedSessions() throws -> [PlaySessionRecord] {
        try database.read { db in
            let sessions: [PlaySessionRecord] = try Self.values(db, table: "sessions")
            return sessions.filter { $0.endedAt == nil }
        }
    }
    public func latestSession(for gameID: GameID) throws -> PlaySessionRecord? {
        try database.read { db in
            let sessions: [PlaySessionRecord] = try Self.values(db, table: "sessions", whereSQL: "source = ? AND game = ?", arguments: [gameID.source, gameID.value])
            return sessions.max { $0.startedAt < $1.startedAt }
        }
    }

    private static func copyMetadata(from source: SourceGameRecord, to target: inout SourceGameRecord) {
        target.summary = source.summary; target.genres = source.genres; target.controllerSupport = source.controllerSupport
        target.coverURL = source.coverURL; target.heroURL = source.heroURL; target.logoURL = source.logoURL
        target.downloadBytes = source.downloadBytes; target.metadataUpdatedAt = source.metadataUpdatedAt
    }
    private static func putPreferences(_ db: Database, _ preferences: LibraryPreferences) throws {
        try db.execute(sql: "INSERT INTO preferences (id, payload) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", arguments: [try encode(preferences)])
    }
    private static func putCollections(_ db: Database, _ collections: [GameCollection]) throws {
        let names = collections.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy({ !$0.isEmpty && $0.count <= 40 }) else { throw CatalogError.invalidCollectionName }
        let normalized = names.map { $0.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        guard Set(normalized).count == normalized.count, Set(collections.map(\.id)).count == collections.count else { throw CatalogError.duplicateCollectionName }
        try db.execute(sql: "DELETE FROM collections")
        for (index, collection) in collections.enumerated() {
            try db.execute(sql: "INSERT INTO collections (id, name, normalizedName, pinned, position) VALUES (?, ?, ?, ?, ?)",
                arguments: [collection.id.uuidString, names[index], normalized[index], collection.isPinned, index])
            for id in collection.gameIDs {
                try db.execute(sql: "INSERT INTO collection_members (collectionID, source, game) VALUES (?, ?, ?)", arguments: [collection.id.uuidString, id.source, id.value])
            }
        }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
    private static func values<T: Decodable>(_ db: Database, table: String, whereSQL: String = "1", arguments: StatementArguments = []) throws -> [T] {
        try Data.fetchAll(db, sql: "SELECT payload FROM \(table) WHERE \(whereSQL)", arguments: arguments).map { try decode(T.self, $0) }
    }
    private static func putGame<T: Encodable>(_ db: Database, table: String, id: GameID, value: T) throws {
        try db.execute(sql: "INSERT INTO \(table) (source, game, payload) VALUES (?, ?, ?) ON CONFLICT(source, game) DO UPDATE SET payload = excluded.payload", arguments: [id.source, id.value, try encode(value)])
    }
    private static func putOperation<T: Encodable>(_ db: Database, table: String, id: UUID, gameID: GameID, value: T) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT source, game FROM \(table) WHERE id = ?", arguments: [id.uuidString]) {
            guard (row["source"] as String) == gameID.source, (row["game"] as String) == gameID.value else { throw CatalogError.identityMismatch }
        }
        try db.execute(sql: "INSERT INTO \(table) (id, source, game, payload) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", arguments: [id.uuidString, gameID.source, gameID.value, try encode(value)])
    }
}
