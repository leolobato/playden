import XCTest
import Domain
import Catalog
@testable import Playden

/// A store that signs in with a code approved on another device, like Epic.
private actor DeviceCodeAuth: SourceAuth {
    private var signedIn: SourceIdentity?
    private var approval: CheckedContinuation<Void, Error>?
    private(set) var signOuts = 0
    var termsURL: URL?
    init(signedIn: SourceIdentity? = nil, termsURL: URL? = nil) { self.signedIn = signedIn; self.termsURL = termsURL }
    var waitingForApproval: Bool { approval != nil }
    func identity() async throws -> SourceIdentity? { signedIn }
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func signInWithDeviceCode(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity {
        onEvent(.deviceCode(userCode: "ABCD1234", verificationURL: URL(string: "https://example.invalid/activate")!,
                            completeURL: URL(string: "https://example.invalid/activate?userCode=ABCD1234")!, expiresAt: .now.addingTimeInterval(600)))
        try await withCheckedThrowingContinuation { approval = $0 }
        if let termsURL { throw SourceFailure.actionRequired(termsURL) }
        let identity = SourceIdentity(sourceID: SourceID.epic, displayName: "Couch Player")
        signedIn = identity
        return identity
    }
    func approve() { approval?.resume(); approval = nil }
    func cancelSignIn() async { approval?.resume(throwing: CancellationError()); approval = nil }
    func signOut() async throws { signedIn = nil; signOuts += 1 }
}

private struct PrimaryAuth: SourceAuth {
    func identity() async throws -> SourceIdentity? { SourceIdentity(sourceID: "fixture", displayName: "Steam Player") }
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity {
        try await Task.sleep(for: .seconds(60)); throw CancellationError()
    }
    func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func cancelSignIn() async {}
    func signOut() async throws {}
}

/// Holds its library until released, so a test can overlap two refreshes.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

private struct PrimarySource: GameSource {
    let id = "fixture", displayName = "Fixture"
    let auth: any SourceAuth = PrimaryAuth()
    var gate: Gate?
    func ownedGames() async throws -> [SourceGameRecord] {
        await gate?.wait()
        return [SourceGameRecord(id: GameID(source: "fixture", value: "1"), title: "Steam Game")]
    }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer { throw SourceFailure.unavailable }
}

private struct DeviceCodeSource: GameSource {
    let id = SourceID.epic, displayName = "Epic Games"
    let auth: any SourceAuth
    var failure: SourceFailure?
    var capabilities: SourceCapabilities { SourceCapabilities(account: .deviceCode, acquisition: .download) }
    func ownedGames() async throws -> [SourceGameRecord] {
        if let failure { throw failure }
        var game = SourceGameRecord(id: GameID(source: SourceID.epic, value: "Sugar"), title: "Epic Game")
        game.platforms = [.windows]
        return [game]
    }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer { throw SourceFailure.unavailable }
}

final class MultiAccountInteractionTests: XCTestCase {
    @MainActor private func waitUntil(_ condition: @escaping @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Condition not met", file: file, line: line)
    }

    @MainActor func testDeviceCodeSignInShowsTheCodeAndSignsInOnlyThatStore() async throws {
        let catalog = try CatalogStore()
        let auth = DeviceCodeAuth()
        let model = LibraryModel(catalog: catalog, preview: false, source: PrimarySource(), otherSources: [DeviceCodeSource(auth: auth)])
        defer { model.stopServices() }
        model.settingsSection = 0; model.settingsRailFocused = false
        XCTAssertEqual(model.storeSettingsRows, [.account("fixture"), .preferMac, .account(SourceID.epic)])
        XCTAssertEqual(SettingsScreen(model: model).settings.map(\.0), ["Steam", "Prefer macOS versions", "Epic Games"])

        model.settingsIndex = 2; model.activateSetting()
        XCTAssertEqual(model.authScreen, .deviceCode)
        XCTAssertEqual(model.authSourceID, SourceID.epic)
        try await waitUntil { model.authDeviceCode != nil }
        XCTAssertEqual(model.authDeviceCode?.userCode, "ABCD1234")
        XCTAssertEqual(model.authQR?.absoluteString, "https://example.invalid/activate?userCode=ABCD1234")
        XCTAssertEqual(model.authenticationActions, ["Get a new code", "Cancel"])

        await auth.approve()
        await model.authTask?.value
        XCTAssertNil(model.authScreen)
        XCTAssertEqual(model.account(SourceID.epic).identity?.displayName, "Couch Player")
        XCTAssertNil(model.identity, "Steam stays signed out")
        XCTAssertTrue(model.signedInToDownloadStore)
        await model.accountSyncTasks[SourceID.epic]?.value
        XCTAssertEqual(model.games.map(\.title), ["Epic Game"])
        XCTAssertEqual(model.storeSettingsRows, [.account("fixture"), .preferMac, .account(SourceID.epic), .signOut(SourceID.epic)])
    }

    @MainActor func testSignedOutStoreRecoveryOpensThatStoresSignIn() async throws {
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog, preview: false, source: PrimarySource(),
                                 otherSources: [DeviceCodeSource(auth: DeviceCodeAuth(), failure: .signedOut)])
        defer { model.stopServices() }
        model.refreshLibrary(SourceID.epic)
        await model.accountSyncTasks[SourceID.epic]?.value
        XCTAssertEqual(model.sessionIssueRecovery, .signIn(SourceID.epic))
        XCTAssertEqual(model.sessionIssue?.stage, "Sign in to Epic Games")
        XCTAssertEqual(model.librarySyncError, "Epic Games: \(SourceFailure.signedOut.localizedDescription)")
        XCTAssertNil(model.syncError, "Steam's own status is untouched")
        XCTAssertEqual(model.sessionIssueActions, ["Sign in again", "Dismiss"])
        model.retrySessionIssue()
        XCTAssertEqual(model.authScreen, .deviceCode)
        XCTAssertEqual(model.authSourceID, SourceID.epic)
    }

    @MainActor func testOneStoresRefreshDoesNotCancelAnothers() async throws {
        let catalog = try CatalogStore()
        let gate = Gate()
        let model = LibraryModel(catalog: catalog, preview: false, source: PrimarySource(gate: gate),
                                 otherSources: [DeviceCodeSource(auth: DeviceCodeAuth())])
        defer { model.stopServices() }
        model.refreshLibrary(model.primaryAccountID)
        model.refreshLibrary(SourceID.epic)
        await model.accountSyncTasks[SourceID.epic]?.value
        XCTAssertTrue(model.syncing, "Steam is still refreshing")
        await gate.release()
        await model.syncTask?.value
        XCTAssertEqual(Set(model.games.map(\.title)), ["Steam Game", "Epic Game"])
        XCTAssertFalse(model.librarySyncing)
    }

    @MainActor func testSigningOutOfOneStoreKeepsTheOthersLibrary() async throws {
        let catalog = try CatalogStore()
        let auth = DeviceCodeAuth(signedIn: SourceIdentity(sourceID: SourceID.epic, displayName: "Couch Player"))
        let model = LibraryModel(catalog: catalog, preview: false, source: PrimarySource(), otherSources: [DeviceCodeSource(auth: auth)])
        defer { model.stopServices() }
        model.startAccountPolling()
        try await waitUntil { model.identity != nil && model.account(SourceID.epic).identity != nil && model.games.count == 2 }

        model.settingsSection = 0; model.settingsRailFocused = false
        model.settingsIndex = try XCTUnwrap(model.storeSettingsRows.firstIndex(of: .signOut(SourceID.epic)))
        model.activateSetting()
        XCTAssertEqual(model.panel, .signOut)
        XCTAssertEqual(model.panelTitle, "Sign out of Epic Games?")
        model.panelIndex = 1; model.activatePanel()
        try await waitUntil { model.account(SourceID.epic).identity == nil && model.games.count == 1 }
        XCTAssertEqual(model.games.map(\.title), ["Steam Game"])
        XCTAssertNotNil(model.identity)
        let signOuts = await auth.signOuts
        XCTAssertEqual(signOuts, 1)
    }

    @MainActor func testTermsToAcceptAreShownAsAQRCodeWithTryAgain() async throws {
        let terms = URL(string: "https://epicgames.example/continue/abc")!
        let auth = DeviceCodeAuth(termsURL: terms)
        let model = LibraryModel(preview: false, source: PrimarySource(), otherSources: [DeviceCodeSource(auth: auth)])
        defer { model.stopServices() }
        model.beginSignIn(SourceID.epic)
        try await waitUntil { await auth.waitingForApproval }
        await auth.approve()
        await model.authTask?.value
        XCTAssertEqual(model.authScreen, .deviceCode)
        XCTAssertEqual(model.authQR, terms)
        XCTAssertNil(model.authDeviceCode)
        XCTAssertEqual(model.authError, SourceFailure.actionRequired(terms).localizedDescription)
        XCTAssertEqual(model.authenticationActions, ["Try again", "Cancel"])
        model.authIndex = 0; model.activateAuthentication()
        XCTAssertEqual(model.authScreen, .deviceCode, "Try again starts a new Epic sign-in, not Steam's")
        XCTAssertEqual(model.authSourceID, SourceID.epic)
    }

    @MainActor func testFirstRunOffersEachStoreAndSignsInToTheChosenOne() async throws {
        let model = LibraryModel(preview: false, source: PrimarySource(), otherSources: [DeviceCodeSource(auth: DeviceCodeAuth())])
        defer { model.stopServices() }
        model.setupScreen = .games; model.setupIndex = 0
        XCTAssertEqual(model.setupActions, ["Sign in to Steam", "Sign in to Epic Games", "Add games on this Mac", "Skip for now"])
        model.setupIndex = 1; model.perform(.confirm)
        XCTAssertEqual(model.setupScreen, .account)
        XCTAssertEqual(model.authScreen, .deviceCode)
        XCTAssertEqual(model.authSourceID, SourceID.epic)
        model.perform(.back)
        XCTAssertEqual(model.setupScreen, .games)
        XCTAssertEqual(model.setupActions[model.setupIndex], "Add games on this Mac")
    }

    @MainActor func testStoreWithoutSteamStillGetsDownloadsAndFirstRunDriveSetup() async throws {
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog, preview: false, otherSources: [DeviceCodeSource(auth: DeviceCodeAuth())])
        defer { model.stopServices() }
        XCTAssertNotNil(model.installQueue)
        XCTAssertNotNil(model.sessions)
        XCTAssertFalse(model.signedInToDownloadStore)
        model.setIdentity(SourceIdentity(sourceID: SourceID.epic, displayName: "Couch Player"), for: SourceID.epic)
        XCTAssertTrue(model.signedInToDownloadStore)
    }
}
