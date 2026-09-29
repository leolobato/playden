import XCTest
import Domain
import Catalog
@testable import Playden

/// A store whose login page ends on an address with a code, like GOG.
private actor WebLoginAuth: SourceAuth {
    private var signedIn: SourceIdentity?
    private(set) var attempts: [String] = []
    init(signedIn: SourceIdentity? = nil) { self.signedIn = signedIn }
    func identity() async throws -> SourceIdentity? { signedIn }
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    nonisolated func webLoginURL() -> URL? { URL(string: "https://login.example.invalid/auth?client=1") }
    nonisolated func redirectMatches(_ url: URL) -> Bool { url.host == "done.example.invalid" }
    func signIn(withRedirect pasted: String) async throws -> SourceIdentity {
        attempts.append(pasted)
        guard pasted.contains("code=good") else { throw SourceFailure.credentialsRejected }
        let identity = SourceIdentity(sourceID: SourceID.gog, displayName: "Couch Player")
        signedIn = identity
        return identity
    }
    func cancelSignIn() async {}
    func signOut() async throws { signedIn = nil }
}

private struct WebLoginSource: GameSource {
    let id = SourceID.gog, displayName = "GOG"
    let auth: any SourceAuth
    var capabilities: SourceCapabilities { SourceCapabilities(account: .webLogin, acquisition: .download) }
    func ownedGames() async throws -> [SourceGameRecord] {
        var game = SourceGameRecord(id: GameID(source: SourceID.gog, value: "1207658901"), title: "GOG Game")
        game.platforms = [.windows, .macOS]
        return [game]
    }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer { throw SourceFailure.unavailable }
}

private struct CodeSource: GameSource {
    let id = SourceID.epic, displayName = "Epic Games"
    let auth: any SourceAuth = NoSourceAuth()
    var capabilities: SourceCapabilities { SourceCapabilities(account: .deviceCode, acquisition: .download) }
    func ownedGames() async throws -> [SourceGameRecord] { [] }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer { throw SourceFailure.unavailable }
}

final class WebLoginInteractionTests: XCTestCase {
    @MainActor private func waitUntil(_ condition: @escaping @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Condition not met", file: file, line: line)
    }

    private static func post(_ url: URL, _ address: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        request.httpBody = Data("address=\(address.addingPercentEncoding(withAllowedCharacters: allowed)!)".utf8)
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor func testPhonePageSignsInOnlyThatStore() async throws {
        let catalog = try CatalogStore()
        let auth = WebLoginAuth()
        let model = LibraryModel(catalog: catalog, preview: false, otherSources: [CodeSource(), WebLoginSource(auth: auth)])
        defer { model.stopServices() }
        model.signInRelayHost = "127.0.0.1"
        model.settingsSection = 0; model.settingsRailFocused = false
        XCTAssertEqual(model.storeSettingsRows.filter { if case .account = $0 { true } else { false } },
                       [.account(SourceID.epic), .account(SourceID.gog)], "a device-code store and a web-login store side by side")
        model.beginSignIn(SourceID.gog)
        XCTAssertEqual(model.authScreen, .webLogin)
        try await waitUntil { model.authWebLogin?.relayURL != nil }
        let relay = try XCTUnwrap(model.authWebLogin?.relayURL)
        XCTAssertEqual(model.authQR, relay, "the QR code opens the phone page")
        XCTAssertEqual(model.authenticationActions, ["Sign in on this Mac", "Paste address", "Cancel"])
        XCTAssertEqual(model.authMessage, "Waiting for your phone")

        let page = String(decoding: try await URLSession(configuration: .ephemeral).data(from: relay).0, as: UTF8.self)
        XCTAssertTrue(page.contains("https://login.example.invalid/auth?client=1"))
        XCTAssertTrue(page.contains("Sign in to GOG"))

        let failed = try await Self.post(relay, "https://done.example.invalid/?code=bad")
        XCTAssertTrue(failed.contains("That address didn"), failed)
        XCTAssertEqual(model.authScreen, .webLogin, "a wrong address keeps the screen open")
        XCTAssertNotNil(model.authError)

        let done = try await Self.post(relay, "https://done.example.invalid/?code=good")
        XCTAssertTrue(done.contains("Signed in to GOG"))
        XCTAssertNil(model.authScreen)
        XCTAssertEqual(model.account(SourceID.gog).identity?.displayName, "Couch Player")
        XCTAssertNil(model.identity, "Steam stays signed out")
        XCTAssertTrue(model.signedInToDownloadStore)
        await model.accountSyncTasks[SourceID.gog]?.value
        XCTAssertEqual(model.games.map(\.title), ["GOG Game"])
        XCTAssertNil(model.signInRelay, "the phone page stops after a sign-in")
    }

    @MainActor func testCancelStopsThePhonePage() async throws {
        let model = LibraryModel(preview: false, otherSources: [WebLoginSource(auth: WebLoginAuth())])
        defer { model.stopServices() }
        model.signInRelayHost = "127.0.0.1"
        model.beginSignIn(SourceID.gog)
        try await waitUntil { model.authWebLogin?.relayURL != nil }
        let relay = try XCTUnwrap(model.authWebLogin?.relayURL)
        model.authIndex = 2; model.activateAuthentication()
        XCTAssertNil(model.authScreen)
        XCTAssertNil(model.signInRelay)
        try await Task.sleep(for: .milliseconds(100))
        let status = try? await (URLSession(configuration: .ephemeral).data(from: relay).1 as? HTTPURLResponse)?.statusCode
        XCTAssertNotEqual(status, 200)
    }

    @MainActor func testWindowAddressFinishesTheSignIn() async throws {
        let auth = WebLoginAuth()
        let model = LibraryModel(preview: false, otherSources: [WebLoginSource(auth: auth)])
        defer { model.stopServices() }
        model.signInRelayHost = "127.0.0.1"
        model.beginSignIn(SourceID.gog)
        let outcome = await model.finishWebLogin("https://done.example.invalid/?code=good", sourceID: SourceID.gog, attempt: model.authAttempt)
        XCTAssertEqual(outcome, .signedIn)
        XCTAssertEqual(model.account(SourceID.gog).identity?.displayName, "Couch Player")
        let stale = await model.finishWebLogin("https://done.example.invalid/?code=good", sourceID: SourceID.gog, attempt: UUID())
        XCTAssertNotEqual(stale, .signedIn, "an address from a cancelled sign-in is refused")
    }

    @MainActor func testFirstRunWithOnlyGOG() async throws {
        let model = LibraryModel(catalog: try CatalogStore(), preview: false, otherSources: [WebLoginSource(auth: WebLoginAuth())])
        defer { model.stopServices() }
        model.signInRelayHost = "127.0.0.1"
        XCTAssertNotNil(model.installQueue)
        model.setupScreen = .games; model.setupIndex = 0
        XCTAssertTrue(model.setupActions.contains("Sign in to GOG"))
        model.setupIndex = model.setupActions.firstIndex(of: "Sign in to GOG")!; model.perform(.confirm)
        XCTAssertEqual(model.setupScreen, .account)
        XCTAssertEqual(model.authScreen, .webLogin)
        XCTAssertEqual(model.authSourceID, SourceID.gog)
        XCTAssertEqual(StoreNames.name(SourceID.gog), "GOG")
    }
}
