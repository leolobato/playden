import XCTest
import Domain
import Catalog
@testable import BigScreen

private actor FixtureAuth: SourceAuth {
    func identity() async throws -> SourceIdentity? { nil }
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity {
        onEvent(.qrChallenge(URL(string: "https://example.invalid/design-test")!, expiresAt: .now.addingTimeInterval(300)))
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
    func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { SourceIdentity(sourceID: "fixture", displayName: "Fixture") }
    func cancelSignIn() async {}
    func signOut() async throws {}
}
private struct AccountFixtureSource: GameSource {
    func installer(for game: SourceGameRecord) throws -> any Installer { throw SourceFailure.unavailable }
    let id = "fixture", displayName = "Fixture"
    let auth: any SourceAuth = FixtureAuth()
    var games: [SourceGameRecord] = []
    func ownedGames() async throws -> [SourceGameRecord] { games }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
}
final class AccountInteractionTests: XCTestCase {
    @MainActor func testSuccessfulSignInImmediatelyLoadsOwnedGames() async throws {
        let catalog = try CatalogStore()
        let games = [SourceGameRecord(id: GameID(source: "fixture", value: "owned"), title: "Owned game")]
        let model = LibraryModel(catalog: catalog, preview: false, source: AccountFixtureSource(games: games))
        model.authScreen = .credentials; model.accountNameDraft = "Fixture"; model.passwordDraft = "fixture-only"
        model.authIndex = 2; model.activateAuthentication()
        let deadline = Date().addingTimeInterval(3)
        while model.games.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.games.map(\.id), games.map(\.id))
        XCTAssertNotNil(model.identity)
        XCTAssertNil(model.authScreen)
        XCTAssertNil(model.syncError)
        model.stopServices()
    }
    @MainActor func testSignInTrapsTabNavigationAndBackCancels() {
        let model = LibraryModel(preview: false, source: AccountFixtureSource())
        model.perform(.confirm)
        XCTAssertEqual(model.authScreen, .qr)
        model.perform(.nextTab)
        XCTAssertEqual(model.tab, .home)
        model.perform(.back)
        XCTAssertNil(model.authScreen)
        XCTAssertNil(model.authQR)
        XCTAssertNil(model.authTask)
    }
    @MainActor func testControllerCredentialFlowMasksSecretsAndClearsOnCancel() {
        let model = LibraryModel(preview: false, source: AccountFixtureSource())
        model.authScreen = .credentials
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .textEditor(.accountName))
        model.insertText("Fixture")
        model.finishText()
        XCTAssertEqual(model.authIndex, 1)
        model.perform(.confirm)
        XCTAssertTrue(model.maskedText)
        model.insertText("not-a-real-password")
        model.finishText()
        XCTAssertEqual(model.authIndex, 2)
        XCTAssertTrue(model.textEditor.text.isEmpty)
        XCTAssertFalse(model.passwordDraft.isEmpty)
        model.perform(.back)
        XCTAssertNil(model.authScreen)
        XCTAssertTrue(model.passwordDraft.isEmpty)
        XCTAssertTrue(model.accountNameDraft.isEmpty)
    }
    @MainActor func testReloadKeepsFocusedGameAcrossMetadataAndSortingChanges() throws {
        let catalog = try CatalogStore()
        let a = GameID(source: "fixture", value: "a"), b = GameID(source: "fixture", value: "b")
        try catalog.replaceSourceCatalog(source: "fixture", games: [SourceGameRecord(id: a, title: "A"), SourceGameRecord(id: b, title: "B")])
        let model = LibraryModel(catalog: catalog, preview: false)
        model.selectTab(.library); model.perform(.move(.right))
        XCTAssertEqual(model.focusedGame?.id, b)
        try catalog.replaceSourceCatalog(source: "fixture", games: [SourceGameRecord(id: a, title: "Z"), SourceGameRecord(id: b, title: "B")])
        model.reloadCatalog()
        XCTAssertEqual(model.focusedGame?.id, b)
        XCTAssertEqual(model.libraryCursor.index, 0)
    }
    @MainActor func testRealHomeUsesSourceHistoryInsteadOfNamedPreviewGames() throws {
        let catalog = try CatalogStore()
        let old = SourceGameRecord(id: GameID(source: "fixture", value: "old"), title: "Old", sourceLastPlayedAt: Date(timeIntervalSince1970: 100))
        let recent = SourceGameRecord(id: GameID(source: "fixture", value: "recent"), title: "Recent", sourceLastPlayedAt: Date(timeIntervalSince1970: 200))
        try catalog.replaceSourceCatalog(source: "fixture", games: [old, recent])
        let model = LibraryModel(catalog: catalog, preview: false)
        XCTAssertEqual(model.rows.first?.games.map(\.id), [recent.id, old.id])
        XCTAssertTrue(model.collections.isEmpty)
        XCTAssertTrue(model.downloadGames.isEmpty)
    }
}
