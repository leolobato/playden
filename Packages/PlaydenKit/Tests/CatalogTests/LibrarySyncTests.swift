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
    func ownedGames() async throws -> [SourceGameRecord] { if let error { throw error }; return records }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord {
        if let metadataError { throw metadataError }
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
}
