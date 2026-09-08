import XCTest
import Domain
import Catalog
@testable import Playden

private actor SizeSource: GameSource, SourceAuth {
    nonisolated let id = "fixture", displayName = "Fixture"
    nonisolated var auth: any SourceAuth { self }
    var key = "a"
    var requests = 0
    var fails = false
    var held = false
    func configure(key: String = "a", fails: Bool = false, held: Bool = false) { self.key = key; self.fails = fails; self.held = held }
    func downloadSizeAccountKey() -> String? { key }
    func downloadSize(for game: SourceGameRecord) async throws -> DownloadSizeEstimate? {
        requests += 1
        while held { try await Task.sleep(for: .milliseconds(10)) }
        if fails { throw SourceFailure.network }
        return .init(accountKey: key, bytes: key == "a" ? 1000 : 2000, manifestIDs: ["1": "9"])
    }
    func ownedGames() -> [SourceGameRecord] { [] }
    func metadata(for game: SourceGameRecord) -> SourceGameRecord { game }
    nonisolated func installer(for game: SourceGameRecord) throws -> any Installer { throw SourceFailure.unavailable }
    func identity() -> SourceIdentity? { .init(sourceID: id, displayName: key) }
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) throws -> SourceIdentity { throw SourceFailure.unavailable }
    func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) throws -> SourceIdentity { throw SourceFailure.unavailable }
    func cancelSignIn() {}
    func signOut() {}
}

@MainActor
final class DownloadSizeTests: XCTestCase {
    private let game = SourceGameRecord(id: .init(source: "fixture", value: "1"), title: "Game")
    private func model(_ catalog: CatalogStore, _ source: SizeSource) throws -> LibraryModel {
        try catalog.replaceSourceCatalog(source: "fixture", games: [game])
        return LibraryModel(catalog: catalog, preview: false, source: source)
    }
    func testFetchOnDetailsThenReuseCacheWithoutAnotherRequest() async throws {
        let catalog = try CatalogStore(), source = SizeSource(), model = try model(catalog, source)
        model.openGame(try XCTUnwrap(model.games.first))
        await model.detailSizeTask?.value
        XCTAssertEqual(model.detailDownloadSize?.bytes, 1000)
        XCTAssertTrue(model.detailSizeLabel(for: model.games[0]).hasPrefix("≈ "))
        model.detailID = nil; model.openGame(model.games[0]); await model.detailSizeTask?.value
        let calls = await source.requests; XCTAssertEqual(calls, 1)
        XCTAssertFalse(model.detailSizeLoading)
        model.stopServices()
    }
    func testStaleSizeRemainsVisibleOfflineAndAccountSwitchDoesNotReuseIt() async throws {
        let catalog = try CatalogStore(), source = SizeSource(), model = try model(catalog, source)
        try catalog.saveDownloadSize(.init(accountKey: "a", bytes: 900, manifestIDs: [:], checkedAt: .distantPast), for: game.id)
        await source.configure(fails: true)
        model.openGame(model.games[0]); await model.detailSizeTask?.value
        XCTAssertEqual(model.detailDownloadSize?.bytes, 900); XCTAssertFalse(model.detailSizeLoading)
        await source.configure(key: "b")
        model.identity = .init(sourceID: "fixture", displayName: "b")
        XCTAssertNil(model.detailDownloadSize)
        await model.detailSizeTask?.value
        XCTAssertEqual(model.detailDownloadSize?.accountKey, "b"); XCTAssertEqual(model.detailDownloadSize?.bytes, 2000)
        model.stopServices()
    }
    func testLeavingDetailsCancelsRequestAndPrecisePlanWins() async throws {
        let catalog = try CatalogStore(), source = SizeSource(), model = try model(catalog, source)
        await source.configure(held: true)
        model.openGame(model.games[0])
        try await Task.sleep(for: .milliseconds(400))
        let task = model.detailSizeTask
        model.detailID = nil
        await task?.value
        XCTAssertNil(try catalog.downloadSize(for: game.id, accountKey: "a"))
        XCTAssertNil(model.detailDownloadSize); XCTAssertFalse(model.detailSizeLoading)
        let plan = InstallPlan(game: game, manifestIDs: ["1": "9"], estimate: .init(downloadBytes: 950, installedBytes: 2000, requiredBytes: 5000),
            launchSpec: .init(executableRelativePath: "Game.exe"), sourcePayload: Data())
        model.cacheResolvedDownloadSize(plan, accountKey: "a")
        model.openGame(model.games[0]); await model.detailSizeTask?.value
        XCTAssertEqual(model.detailDownloadSize?.bytes, 950); XCTAssertEqual(model.detailDownloadSize?.precise, true)
        XCTAssertFalse(model.detailSizeLabel(for: model.games[0]).hasPrefix("≈"))
        model.stopServices()
    }
}
