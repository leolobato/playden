import XCTest
import Domain
@testable import Catalog

private struct NoAccount: SourceAuth {
    func identity() async throws -> SourceIdentity? { nil }
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func cancelSignIn() async {}
    func signOut() async throws {}
}
private struct FixtureSource: GameSource {
    func installer(for game: SourceGameRecord) throws -> any Installer { throw SourceFailure.unavailable }
    let id = "fixture", displayName = "Fixture store"
    var auth: any SourceAuth { NoAccount() }
    var records: [SourceGameRecord]
    var error: SourceFailure?
    var metadataError: SourceFailure?
    /// Metadata requests after this many succeed are throttled, like a long Steam refresh.
    var metadataLimit = Int.max
    let requested = Requested()
    final class Requested: @unchecked Sendable { var ids: [String] = []; let lock = NSLock() }
    func ownedGames() async throws -> [SourceGameRecord] { if let error { throw error }; return records }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord {
        if let metadataError { throw metadataError }
        let count = requested.lock.withLock { requested.ids.append(game.id.value); return requested.ids.count }
        if count > metadataLimit { throw SourceFailure.throttled }
        var result = game; result.summary = "Enriched"; result.metadataUpdatedAt = .now; return result
    }
}
final class LibrarySyncTests: XCTestCase {
    func testRefreshLoadsOwnedBeforeMetadataAndKeepsEdits() async throws {
        let store = try CatalogStore()
        let id = GameID(source: "fixture", value: "one")
        try store.saveEdits(GameEdits(isFavorite: true), for: id)
        let sync = LibrarySyncCoordinator(catalog: store, metadataDelay: .zero)
        let result = try await sync.refresh(source: FixtureSource(records: [SourceGameRecord(id: id, title: "A game")]))
        XCTAssertEqual(result.ownedCount, 1); XCTAssertEqual(result.metadataUpdated, 1)
        let entry = try XCTUnwrap(store.snapshot().entries.first)
        XCTAssertEqual(entry.source.summary, "Enriched"); XCTAssertTrue(entry.edits.isFavorite)
        let again = try await sync.refresh(source: FixtureSource(records: [SourceGameRecord(id: id, title: "A game")]))
        XCTAssertEqual(again.metadataUpdated, 0)
    }
    func testOfflineFailurePreservesPreviouslySyncedCatalog() async throws {
        let store = try CatalogStore()
        let record = SourceGameRecord(id: GameID(source: "fixture", value: "one"), title: "A game")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.replaceSourceCatalog(source: "fixture", games: [record], syncedAt: date)
        let sync = LibrarySyncCoordinator(catalog: store, metadataDelay: .zero)
        do { _ = try await sync.refresh(source: FixtureSource(records: [], error: .network)); XCTFail("Offline refresh must fail") } catch {}
        XCTAssertEqual(try store.snapshot().entries.map(\.source), [record])
        XCTAssertEqual(try store.lastSync(for: "fixture"), date)
    }
    func testOptionalMetadataFailureDoesNotDiscardOwnedGames() async throws {
        let store = try CatalogStore()
        let record = SourceGameRecord(id: GameID(source: "fixture", value: "one"), title: "A game")
        let sync = LibrarySyncCoordinator(catalog: store, metadataDelay: .zero)
        let result = try await sync.refresh(source: FixtureSource(records: [record], metadataError: .throttled))
        XCTAssertEqual(result.ownedCount, 1); XCTAssertEqual(result.metadataUpdated, 0); XCTAssertEqual(result.metadataFailed, 1)
        XCTAssertEqual(try store.snapshot().entries.map(\.source), [record])
    }
    func testThrottledRefreshReachesTheStalestMetadataFirst() async throws {
        let recent = Date.now.addingTimeInterval(-7 * 3600), old = Date.now.addingTimeInterval(-7 * 24 * 3600)
        let records = [SourceGameRecord(id: GameID(source: "fixture", value: "a"), title: "A", metadataUpdatedAt: recent),
                       SourceGameRecord(id: GameID(source: "fixture", value: "b"), title: "B", metadataUpdatedAt: recent),
                       SourceGameRecord(id: GameID(source: "fixture", value: "t"), title: "T", metadataUpdatedAt: old)]
        let store = try CatalogStore()
        try store.replaceSourceCatalog(source: "fixture", games: records)
        let source = FixtureSource(records: records.map { SourceGameRecord(id: $0.id, title: $0.title) }, metadataLimit: 1)
        let result = try await LibrarySyncCoordinator(catalog: store, metadataDelay: .zero).refresh(source: source)
        XCTAssertEqual(result.metadataUpdated, 1)
        XCTAssertEqual(try store.snapshot().entries.first { $0.id.value == "t" }?.source.summary, "Enriched")
    }
}
