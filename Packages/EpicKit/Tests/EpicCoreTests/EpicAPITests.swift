import XCTest
@testable import EpicCore

/// Answers requests from a routing closure and records what was sent.
final class StubTransport: EpicTransport, @unchecked Sendable {
    typealias Route = (URLRequest) throws -> (Int, Data)
    private let lock = NSLock()
    private var route: Route
    private(set) var requests: [URLRequest] = []

    init(_ route: @escaping Route) { self.route = route }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler: Route = lock.withLock { requests.append(request); return route }
        let (status, data) = try handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    var paths: [String] { lock.withLock { requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" } } }
}

func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
func form(_ request: URLRequest) -> [String: String] {
    let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map {
        let pair = $0.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        return (pair[0], pair.count > 1 ? pair[1] : "")
    })
}

final class EpicAuthTests: XCTestCase {
    private let config = EpicClientConfig.default
    private func basic(_ client: EpicClientConfig.Client) -> String { client.basicAuthorization }
    private let noPause: @Sendable (Double) async throws -> Void = { _ in }

    func testDeviceCodeSignInPollsUntilApprovalThenTradesForLauncherSession() async throws {
        let polls = LockedCounter()
        let config = self.config
        let transport = StubTransport { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            switch (request.httpMethod, request.url!.path) {
            case ("POST", "/account/api/oauth/token"):
                let f = form(request)
                switch f["grant_type"] {
                case "client_credentials":
                    XCTAssertEqual(auth, config.deviceCode.basicAuthorization)
                    return (200, json(["access_token": "client", "expires_in": 14400]))
                case "device_code":
                    XCTAssertEqual(f["device_code"], "dev-123")
                    if polls.increment() < 3 {
                        return (400, json(["errorCode": "errors.com.epicgames.account.oauth.authorization_pending"]))
                    }
                    return (200, json(["access_token": "console-user", "account_id": "acct", "refresh_token": "console-refresh"]))
                case "exchange_code":
                    XCTAssertEqual(auth, config.launcher.basicAuthorization)
                    XCTAssertEqual(f["exchange_code"], "ex-1"); XCTAssertEqual(f["token_type"], "eg1")
                    return (200, json(["access_token": "eg1~launcher", "expires_in": 7200, "refresh_token": "launcher-refresh",
                                       "refresh_expires": 28800, "account_id": "acct", "displayName": "Leo"]))
                default: XCTFail("grant \(f)"); return (400, Data())
                }
            case ("POST", "/account/api/oauth/deviceAuthorization"):
                XCTAssertEqual(auth, "bearer client")
                return (200, json(["user_code": "ABCD1234", "device_code": "dev-123",
                                   "verification_uri": "https://www.epicgames.com/activate",
                                   "verification_uri_complete": "https://www.epicgames.com/activate?userCode=ABCD1234",
                                   "expires_in": 600, "interval": 10]))
            case ("GET", "/account/api/oauth/exchange"):
                XCTAssertEqual(auth, "bearer console-user")
                return (200, json(["code": "ex-1", "expiresInSeconds": 300, "creatingClientId": config.deviceCode.id]))
            case ("DELETE", "/account/api/oauth/sessions/kill/console-user"):
                return (204, Data())
            default: XCTFail("unexpected \(request)"); return (404, Data())
            }
        }
        let auth = EpicAuth(transport: transport, pause: noPause)
        let authorization = try await auth.startDeviceAuthorization()
        XCTAssertEqual(authorization.userCode, "ABCD1234")
        XCTAssertEqual(authorization.completeVerificationURL.absoluteString, "https://www.epicgames.com/activate?userCode=ABCD1234")
        XCTAssertEqual(authorization.interval, 10)

        let session = try await auth.completeDeviceAuthorization(authorization)
        XCTAssertEqual(session.accessToken, "eg1~launcher")
        XCTAssertEqual(session.refreshToken, "launcher-refresh")
        XCTAssertEqual(session.displayName, "Leo")
        XCTAssertEqual(polls.value, 3)
        XCTAssertEqual(transport.paths.last, "DELETE /account/api/oauth/sessions/kill/console-user")
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == config.userAgent })
    }

    func testDeviceCodeExpiresWhenThePlayerNeverApproves() async throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 0))
        let transport = StubTransport { _ in (400, json(["errorCode": "errors.com.epicgames.account.oauth.authorization_pending"])) }
        let auth = EpicAuth(transport: transport, pause: { clock.advance($0) }, now: { clock.now })
        let authorization = EpicDeviceAuthorization(userCode: "X", deviceCode: "d", verificationURL: URL(string: "https://e")!,
                                                    completeVerificationURL: URL(string: "https://e")!,
                                                    expiresAt: Date(timeIntervalSince1970: 60), interval: 10)
        do { _ = try await auth.completeDeviceAuthorization(authorization); XCTFail() }
        catch { XCTAssertEqual(error as? EpicError, .deviceCodeExpired) }
        XCTAssertEqual(transport.requests.count, 6)
    }

    func testRejectedRefreshMeansSignInAgainButOutageDoesNot() async throws {
        let session = EpicSession(accessToken: "a", expiresAt: .distantPast, refreshToken: "r", refreshExpiresAt: .distantFuture,
                                  accountID: "acct", displayName: "Leo")
        let rejected = EpicAuth(transport: StubTransport { _ in (400, json(["errorCode": "errors.com.epicgames.account.auth_token.invalid_refresh_token"])) },
                                pause: noPause)
        do { _ = try await rejected.valid(session); XCTFail() }
        catch { XCTAssertEqual(error as? EpicError, .invalidCredentials("errors.com.epicgames.account.auth_token.invalid_refresh_token")) }

        let outage = EpicAuth(transport: StubTransport { _ in (503, Data()) }, pause: noPause)
        do { _ = try await outage.valid(session); XCTFail() }
        catch { XCTAssertEqual(error as? EpicError, .http(status: 503, code: nil, message: nil)) }

        let offline = EpicAuth(transport: StubTransport { _ in throw URLError(.notConnectedToInternet) }, pause: noPause)
        do { _ = try await offline.valid(session); XCTFail() }
        catch { guard case .network = error as? EpicError else { return XCTFail("\(error)") } }
    }

    func testValidSessionIsNotRefreshed() async throws {
        let transport = StubTransport { _ in XCTFail("no request"); return (500, Data()) }
        let session = EpicSession(accessToken: "a", expiresAt: Date().addingTimeInterval(3600), refreshToken: "r",
                                  refreshExpiresAt: .distantFuture, accountID: "acct", displayName: "Leo")
        let result = try await EpicAuth(transport: transport, pause: noPause).valid(session)
        XCTAssertEqual(result, session)
    }

    func testCorrectiveActionCarriesTheContinuationURL() async throws {
        let transport = StubTransport { _ in
            (400, json(["errorCode": "errors.com.epicgames.oauth.corrective_action_required", "correctiveAction": "PRIVACY_POLICY_ACCEPTANCE",
                        "continuationUrl": "https://www.epicgames.com/id/continue"]))
        }
        let session = EpicSession(accessToken: "a", expiresAt: .distantPast, refreshToken: "r", refreshExpiresAt: .distantFuture,
                                  accountID: "acct", displayName: "")
        do { _ = try await EpicAuth(transport: transport, pause: noPause).refresh(session); XCTFail() }
        catch { XCTAssertEqual(error as? EpicError, .correctiveAction(URL(string: "https://www.epicgames.com/id/continue"))) }
    }

    func testThrottledRequestsAreRetried() async throws {
        let calls = LockedCounter()
        let transport = StubTransport { _ in calls.increment() < 2 ? (429, Data()) : (200, json(["code": "ok"])) }
        let code = try await EpicAuth(transport: transport, pause: noPause).exchangeCode(accessToken: "a")
        XCTAssertEqual(code, "ok")
        XCTAssertEqual(calls.value, 2)
    }
}

final class EpicLibraryAPITests: XCTestCase {
    private let noPause: @Sendable (Double) async throws -> Void = { _ in }

    func testLibraryItemsFollowCursorPages() async throws {
        let transport = StubTransport { request in
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
            switch cursor {
            case nil: return (200, json(["records": [["namespace": "n1", "catalogItemId": "c1", "appName": "A"]],
                                         "responseMetadata": ["nextCursor": "p2"]]))
            case "p2": return (200, json(["records": [["namespace": "n2", "catalogItemId": "c2"]], "responseMetadata": [:]]))
            default: XCTFail(); return (404, Data())
            }
        }
        let records = try await EpicLibraryAPI(transport: transport, pause: noPause).libraryItems(accessToken: "t")
        XCTAssertEqual(records.map(\.catalogItemId), ["c1", "c2"])
        XCTAssertNil(records[1].appName)
    }

    func testCatalogItemExposesLaunchAttributesAndArtwork() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url!.path, "/catalog/api/shared/namespace/ns/bulk/items")
            return (200, json(["cat": [
                "id": "cat", "title": "Sugar", "description": "A game",
                "keyImages": [["type": "Thumbnail", "url": "https://img/thumb"], ["type": "DieselGameBoxTall", "url": "https://img/tall"]],
                "categories": [["path": "games"], ["path": "applications"]],
                "customAttributes": ["CanRunOffline": ["type": "STRING", "value": "false"],
                                     "OwnershipToken": ["type": "STRING", "value": "true"],
                                     "AdditionalCommandline": ["type": "STRING", "value": "-skipintro"],
                                     "ThirdPartyManagedApp": ["type": "STRING", "value": "The EA App"]],
            ]]))
        }
        let item = try await XCTUnwrapAsync(await EpicLibraryAPI(transport: transport, pause: noPause)
            .catalogItem(namespace: "ns", catalogItemID: "cat", accessToken: "t"))
        XCTAssertEqual(item.image(["DieselGameBoxTall", "Thumbnail"])?.absoluteString, "https://img/tall")
        XCTAssertFalse(item.canRunOffline)
        XCTAssertTrue(item.requiresOwnershipToken)
        XCTAssertEqual(item.additionalCommandLine, "-skipintro")
        XCTAssertEqual(item.thirdPartyStore, "The EA App")
        XCTAssertFalse(item.isDLC)
    }

    func testManifestLocationKeepsTokensOnManifestURLsOnlyAndReadsSidecar() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url!.path, "/launcher/api/public/assets/v2/platform/Windows/namespace/ns/catalogItem/cat/app/App/label/Live")
            return (200, json(["elements": [[
                "appName": "App", "buildVersion": "1.0", "hash": "ABCDEF",
                "manifests": [["uri": "https://cdn1.example/Builds/Org/App/x.manifest", "queryParams": [["name": "cf_token", "value": "t1"]]],
                              ["uri": "https://cdn2.example/Builds/Org/App/x.manifest"]],
                "secrets": ["00000001000000020000000300000004": "aa"],
                "sidecar": ["config": "{\"deploymentId\":\"dep-1\"}", "rvn": 2],
            ]]]))
        }
        let location = try await EpicLibraryAPI(transport: transport, pause: noPause)
            .manifestLocation(platform: .windows, namespace: "ns", catalogItemID: "cat", appName: "App", accessToken: "t")
        XCTAssertEqual(location.manifestURLs.map(\.absoluteString),
                       ["https://cdn1.example/Builds/Org/App/x.manifest?cf_token=t1", "https://cdn2.example/Builds/Org/App/x.manifest"])
        XCTAssertEqual(location.baseURLs.map(\.absoluteString), ["https://cdn1.example/Builds/Org/App/", "https://cdn2.example/Builds/Org/App/"])
        XCTAssertEqual(location.sha1, "abcdef")
        XCTAssertEqual(location.deploymentID, "dep-1")
        XCTAssertEqual(location.secrets.count, 1)
    }

    func testManifestDownloadFallsBackToTheNextCDNOnBadBytes() async throws {
        let good = try fixture("overlay.manifest")
        let transport = StubTransport { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return request.url!.host == "bad.example" ? (200, Data("junk".utf8)) : (200, good)
        }
        let location = EpicManifestLocation(manifestURLs: [URL(string: "https://bad.example/m")!, URL(string: "https://good.example/m")!],
                                            baseURLs: [], sha1: EpicCodec.sha1(good).hexString, buildVersion: "", secrets: [:])
        let (manifest, raw) = try await EpicLibraryAPI(transport: transport, pause: noPause).manifest(at: location)
        XCTAssertEqual(raw, good)
        XCTAssertEqual(manifest.files.count, 151)
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    @discardableResult func increment() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

final class LockedClock: @unchecked Sendable {
    private let lock = NSLock(); private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: Double) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
