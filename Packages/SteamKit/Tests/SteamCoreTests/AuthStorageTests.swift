import XCTest
@testable import SteamCore

private final class MemoryCredentials: AuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredAuth?
    var rejectWrites = false
    func load() throws -> StoredAuth? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ auth: StoredAuth) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectWrites { throw CocoaError(.fileWriteNoPermission) }; value = auth
    }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
final class AuthStorageTests: XCTestCase {
    func testRenewalUsesInjectedStoreAndNeverWritesCLITokenFile() async throws {
        let oldDirectory = TokenStore.directory
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        TokenStore.directory = temporary
        defer { TokenStore.directory = oldDirectory; try? FileManager.default.removeItem(at: temporary) }
        let store = MemoryCredentials()
        var auth = StoredAuth(accountName: "fixture", steamID: 1, refreshToken: "fixture-refresh")
        let token = try await SteamAuth.validAccessToken(&auth, store: store) { _ in "fixture-renewed" }
        XCTAssertEqual(token, "fixture-renewed")
        XCTAssertEqual(try store.load()?.accessToken, token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }
    func testStorageFailureDoesNotPublishUnpersistedCredentials() async throws {
        let store = MemoryCredentials(); store.rejectWrites = true
        var auth = StoredAuth(accountName: "fixture", steamID: 1, refreshToken: "fixture-refresh")
        do {
            _ = try await SteamAuth.validAccessToken(&auth, store: store) { _ in "new-token" }
            XCTFail("Write must fail")
        } catch { XCTAssertNil(auth.accessToken) }
        XCTAssertNil(try store.load())
    }
    func testMalformedLibraryResponseDoesNotMasqueradeAsEmptyLibrary() throws {
        XCTAssertThrowsError(try SteamLibrary.parseOwnedGames(["response": [:]]))
        XCTAssertThrowsError(try SteamLibrary.parseOwnedGames(["response": ["game_count": 2, "games": [["appid": 1]]]]))
        XCTAssertThrowsError(try SteamLibrary.parseOwnedGames(["response": ["games": [["appid": -1]]]]))
        XCTAssertTrue(try SteamLibrary.parseOwnedGames(["response": ["game_count": 0]]).isEmpty)
        let games = try SteamLibrary.parseOwnedGames(["response": ["game_count": 1, "games": [["appid": 268910, "name": "Cuphead", "playtime_forever": 60, "rtime_last_played": 1_700_000_000.0]]]])
        XCTAssertEqual(games[0].playtimeMinutes, 60)
        XCTAssertEqual(games[0].lastPlayedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }
}
