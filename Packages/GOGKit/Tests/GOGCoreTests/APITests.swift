import XCTest
@testable import GOGCore

/// Answers requests from a handler and records them.
final class StubTransport: GOGTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URLRequest] = []
    let handler: @Sendable (URLRequest) throws -> (Int, Data, [String: String])

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data, [String: String])) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { log } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { log.append(request) }
        let (status, data, headers) = try handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

func json(_ text: String) -> Data { Data(text.utf8) }
func query(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

final class APITests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testCodeExchangeSendsTheGalaxyRedirect() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.host, "auth.gog.com")
            XCTAssertEqual(query(request, "grant_type"), "authorization_code")
            XCTAssertEqual(query(request, "code"), "abc")
            XCTAssertEqual(query(request, "redirect_uri"), "https://embed.gog.com/on_login_success?origin=client")
            return (200, json(#"{"access_token":"A","expires_in":3600,"refresh_token":"R","user_id":"42","token_type":"bearer"}"#), [:])
        }
        let auth = GOGAuth(transport: transport, pause: { _ in }, now: { self.now })
        let session = try await auth.exchange(code: try GOGAuth.code(from: "https://embed.gog.com/on_login_success?origin=client&code=abc"))
        XCTAssertEqual(session, GOGSession(accessToken: "A", expiresAt: now.addingTimeInterval(3600), refreshToken: "R", userID: "42"))
        XCTAssertEqual(transport.requests.first?.url?.absoluteString.contains("redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient"), true)
    }

    func testRefreshKeepsTheNameAndOnlyRunsNearExpiry() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(query(request, "grant_type"), "refresh_token")
            XCTAssertEqual(query(request, "refresh_token"), "R")
            return (200, json(#"{"access_token":"B","expires_in":3600,"refresh_token":"R2","user_id":"42"}"#), [:])
        }
        let auth = GOGAuth(transport: transport, pause: { _ in }, now: { self.now })
        let fresh = GOGSession(accessToken: "A", expiresAt: now.addingTimeInterval(1200), refreshToken: "R", userID: "42", displayName: "leo")
        let unchanged = try await auth.valid(fresh)
        XCTAssertEqual(unchanged, fresh)
        XCTAssertTrue(transport.requests.isEmpty)
        var stale = fresh; stale.expiresAt = now.addingTimeInterval(300)
        let refreshed = try await auth.valid(stale)
        XCTAssertEqual(refreshed.accessToken, "B")
        XCTAssertEqual(refreshed.refreshToken, "R2")
        XCTAssertEqual(refreshed.displayName, "leo")
    }

    func testRejectedRefreshIsInvalidCredentials() async {
        let transport = StubTransport { _ in (400, json(#"{"error":"invalid_grant","error_description":"The refresh token is invalid."}"#), [:]) }
        let auth = GOGAuth(transport: transport, pause: { _ in }, now: { self.now })
        do {
            _ = try await auth.refresh(GOGSession(accessToken: "A", expiresAt: now, refreshToken: "R", userID: "1"))
            XCTFail("expected a failure")
        } catch GOGError.invalidCredentials(let detail) {
            XCTAssertEqual(detail, "The refresh token is invalid.")
        } catch { XCTFail("\(error)") }
    }

    func testServerErrorsRetryThenFail() async {
        let transport = StubTransport { _ in (503, Data(), [:]) }
        let api = GOGAPI(transport: transport, pause: { _ in })
        do { _ = try await api.ownedProductIDs(accessToken: "A"); XCTFail() }
        catch GOGError.http(let status, _, _) { XCTAssertEqual(status, 503) }
        catch { XCTFail("\(error)") }
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testOwnedIDsSendTheBearerToken() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer A")
            return (200, json(#"{"owned":[1,2,3]}"#), [:])
        }
        let owned = try await GOGAPI(transport: transport, pause: { _ in }).ownedProductIDs(accessToken: "A")
        XCTAssertEqual(owned, [1, 2, 3])
    }

    func testGamesDBEntryArtworkAndETag() async throws {
        let body = try fixture("gamesdb-game.json")
        let transport = StubTransport { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "W/\"1\"" { return (304, Data(), [:]) }
            return (200, body, ["ETag": "W/\"1\""])
        }
        let api = GOGAPI(transport: transport, pause: { _ in })
        guard case .entry(let entry, let etag) = try await api.gamesDBEntry(productID: "2116968103", etag: nil) else { return XCTFail() }
        XCTAssertEqual(etag, "W/\"1\"")
        XCTAssertEqual(entry.title, "VirtuaVerse")
        XCTAssertTrue(entry.isListedGame)
        XCTAssertEqual(Set(entry.systems), ["windows", "osx", "linux"])
        XCTAssertEqual(entry.genres.first, "Adventure")
        XCTAssertEqual(entry.releaseDate, "2020-05-12T00:00:00+0000")
        XCTAssertEqual(entry.cover?.absoluteString.hasSuffix(".jpg?namespace=gamesdb"), true)
        XCTAssertFalse(entry.cover?.absoluteString.contains("{") ?? true)
        XCTAssertNotNil(entry.hero)
        let again = try await api.gamesDBEntry(productID: "2116968103", etag: etag)
        XCTAssertEqual(again, .notModified)
    }

    func testGamesDBFiltersAndMissing() async throws {
        let spam = GOGGameEntry(gamesDB: try JSONDecoder().decode(GOGJSON.self, from: json(#"{"type":"spam","title":{"*":"Pack"},"game":{"visible_in_library":false}}"#)), productID: "1")
        XCTAssertFalse(spam.isListedGame)
        let dlc = GOGGameEntry(gamesDB: try JSONDecoder().decode(GOGJSON.self, from: json(#"{"type":"dlc","title":{"*":"DLC"},"game":{"visible_in_library":true}}"#)), productID: "2")
        XCTAssertFalse(dlc.isListedGame)
        let transport = StubTransport { _ in (404, json(#"{"error":"not found"}"#), [:]) }
        let missing = try await GOGAPI(transport: transport, pause: { _ in }).gamesDBEntry(productID: "3", etag: nil)
        XCTAssertEqual(missing, .missing)
    }

    func testLogoOnlyWhenPNG() async throws {
        let png = StubTransport { _ in (200, json(#"{"_links":{"logo":{"href":"https://images.gog-statics.com/a.png"}}}"#), [:]) }
        let logo = try await GOGAPI(transport: png, pause: { _ in }).logo(productID: "1")
        XCTAssertEqual(logo?.absoluteString, "https://images.gog-statics.com/a.png")
        let jpg = StubTransport { _ in (200, json(#"{"_links":{"logo":{"href":"https://images.gog-statics.com/a_glx_logo.jpg"}}}"#), [:]) }
        let none = try await GOGAPI(transport: jpg, pause: { _ in }).logo(productID: "1")
        XCTAssertNil(none)
    }

    func testFetcherRenewsAnExpiredSecureLink() async throws {
        let chunkBody = try fixture("dependency-chunk.bin")
        let chunk = GOGChunk(md5: "6edd4ea41d69ba42d4724319f3fe0dc9", compressedMd5: "3f296756b344d71d92e22377b325c042", size: 3833, compressedSize: 1679)
        let links = LockedCounter(), cdn = LockedCounter()
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/secure_link") == true {
                let n = links.next()
                XCTAssertEqual(query(request, "generation"), "2")
                return (200, json(#"{"urls":[{"endpoint_name":"fastly","url_format":"{base_url}/token={token}{path}","parameters":{"base_url":"https://cdn.test","path":"/content-system/v2/store/7","token":"t\#(n)"},"priority":10}]}"#), [:])
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "chunk URLs are signed; no bearer token")
            let first = cdn.next() == 1
            XCTAssertEqual(request.url?.absoluteString, "https://cdn.test/token=t\(first ? 1 : 2)/content-system/v2/store/7/3f/29/3f296756b344d71d92e22377b325c042")
            return first ? (403, Data(), [:]) : (200, chunkBody, [:])
        }
        let manifest = GOGInstallManifest(generation: 2, productID: "7", buildID: "b", platform: "windows", versionName: nil,
                                          installDirectory: "G", language: "en-US", products: ["7"], dependencies: [], files: [])
        let fetcher = GOGCDNFetcher(manifest: manifest, api: GOGAPI(transport: transport, pause: { _ in }), transport: transport,
                                    pause: { _ in }, accessToken: { "A" })
        let data = try await fetcher.chunk(chunk, product: "7")
        XCTAssertEqual(data, chunkBody)
        XCTAssertEqual(links.value, 2)
    }

    func testFetcherFailsOverAndRangesGen1() async throws {
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/secure_link") == true {
                XCTAssertEqual(query(request, "type"), "depot")
                XCTAssertEqual(query(request, "path"), "/windows/123/")
                return (200, json(#"{"urls":[{"endpoint_name":"gcore","url_format":"{base_url}/{path}?s={token}","parameters":{"base_url":"https://b.test","path":"v1/depots/9","token":"x"},"priority":1,"fallback_only":true},{"endpoint_name":"fastly","url_format":"{base_url}{path}","parameters":{"base_url":"https://a.test","path":"/v1/depots/9"},"priority":10}]}"#), [:])
            }
            if request.url?.host == "a.test" { return (500, Data(), [:]) }
            XCTAssertEqual(request.url?.absoluteString, "https://b.test/v1/depots/9/main.bin?s=x")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=100-104")
            return (206, json("hello"), [:])
        }
        let manifest = GOGInstallManifest(generation: 1, productID: "9", buildID: "b", platform: "windows", versionName: nil,
                                          installDirectory: "G", language: "en-US", products: ["9"], dependencies: [], v1LinkPath: "/windows/123/", files: [])
        let fetcher = GOGCDNFetcher(manifest: manifest, api: GOGAPI(transport: transport, pause: { _ in }), transport: transport,
                                    pause: { _ in }, accessToken: { "A" })
        let data = try await fetcher.range(product: "9", offset: 100, length: 5)
        XCTAssertEqual(data, json("hello"))
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}
