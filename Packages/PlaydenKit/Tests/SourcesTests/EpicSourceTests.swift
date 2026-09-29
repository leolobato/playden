import XCTest
import CryptoKit
import Domain
import EpicCore
@testable import Sources

/// Epic's account, launcher, catalog and CDN services, in memory.
private final class FakeEpic: EpicTransport, @unchecked Sendable {
    struct Game { var appName: String; var namespace = "ns"; var item: String; var title: String; var attributes: [String: String] = [:]
                  var categories = ["games"]; var dlc = false }
    private let lock = NSLock()
    var games: [Game] = []
    var files: [String: Data] = [:]      // install path -> content
    var launchExe = "Binaries/Win64/Game.exe"
    var launchCommand = "-nosplash"
    var accessToken = "eg1~fresh"
    var refreshRejected = false
    var offline = false
    private(set) var requests: [String] = []
    private(set) var exchangeCodes = 0
    private(set) var deviceCodes = 0
    private(set) var cdn: [String: Data] = [:]
    private(set) var manifestData = Data()

    func count(_ prefix: String) -> Int { lock.withLock { requests.filter { $0.hasPrefix(prefix) }.count } }

    /// Builds a JSON manifest with one chunk per file.
    func publishBuild() throws {
        var chunkSizes: [String: String] = [:], hashes: [String: String] = [:], shas: [String: String] = [:], groups: [String: String] = [:]
        var fileList: [[String: Any]] = []
        for (index, (path, data)) in files.sorted(by: { $0.key < $1.key }).enumerated() {
            let guid = EpicGUID(a: UInt32(index + 1), b: 2, c: 3, d: 4)
            let hex = guid.description
            let raw = try EpicChunk.encode(guid: guid, data: data)
            func blob(_ value: UInt64, bytes: Int = 4) -> String { (0..<bytes).map { String(format: "%03d", (value >> (8 * UInt64($0))) & 0xFF) }.joined() }
            chunkSizes[hex] = blob(UInt64(raw.count), bytes: 8); hashes[hex] = blob(0, bytes: 8)
            shas[hex] = Data(Insecure.SHA1.hash(data: data)).map { String(format: "%02x", $0) }.joined()
            groups[hex] = blob(UInt64(index % 100), bytes: 1)
            cdn["ChunksV3/\(String(format: "%02d", index % 100))/0000000000000000_\(hex).chunk"] = raw
            fileList.append(["Filename": path, "FileHash": Data(Insecure.SHA1.hash(data: data)).map { String(format: "%03d", $0) }.joined(),
                             "bIsUnixExecutable": path.hasSuffix(".exe"),
                             "FileChunkParts": [["Guid": hex, "Offset": blob(0), "Size": blob(UInt64(data.count))]]])
        }
        let manifest: [String: Any] = ["ManifestFileVersion": "013000000000", "AppNameString": games.first?.appName ?? "",
                                       "BuildVersionString": "1.0", "LaunchExeString": launchExe.replacingOccurrences(of: "/", with: "\\"),
                                       "LaunchCommand": launchCommand, "FileManifestList": fileList, "ChunkFilesizeList": chunkSizes,
                                       "ChunkHashList": hashes, "ChunkShaList": shas, "DataGroupList": groups]
        manifestData = try JSONSerialization.data(withJSONObject: manifest)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        lock.withLock { requests.append("\(method) \(url.host ?? "")\(url.path)") }
        if offline { throw URLError(.notConnectedToInternet) }
        func reply(_ status: Int, _ body: Any) -> (Data, HTTPURLResponse) {
            let data = (body as? Data) ?? (try! JSONSerialization.data(withJSONObject: body))
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        switch (method, url.path) {
        case ("POST", "/account/api/oauth/token"):
            if form.contains("grant_type=refresh_token") {
                if refreshRejected { return reply(400, ["errorCode": "errors.com.epicgames.account.auth_token.invalid_refresh_token"]) }
                return reply(200, ["access_token": accessToken, "expires_in": 7200, "refresh_token": "rt-2", "refresh_expires": 28800,
                                   "account_id": "acct", "displayName": "Couch Player"])
            }
            if form.contains("grant_type=client_credentials") { return reply(200, ["access_token": "client", "expires_in": 14400]) }
            if form.contains("grant_type=device_code") {
                // The first code expires unapproved; the player approves the second.
                return form.contains("device_code=dev1")
                    ? reply(400, ["errorCode": "errors.com.epicgames.account.oauth.expired_token"])
                    : reply(200, ["access_token": "console", "account_id": "acct"])
            }
            if form.contains("grant_type=exchange_code") {
                return reply(200, ["access_token": "eg1~launcher", "expires_in": 7200, "refresh_token": "rt-new", "refresh_expires": 28800,
                                   "account_id": "acct", "displayName": "Couch Player"])
            }
            return reply(400, ["errorCode": "unexpected"])
        case ("POST", "/account/api/oauth/deviceAuthorization"):
            let n = lock.withLock { deviceCodes += 1; return deviceCodes }
            return reply(200, ["user_code": "CODE\(n)", "device_code": "dev\(n)", "verification_uri": "https://www.epicgames.com/activate",
                               "verification_uri_complete": "https://www.epicgames.com/activate?userCode=CODE\(n)", "expires_in": 600, "interval": 1])
        case ("GET", "/account/api/oauth/exchange"):
            lock.withLock { exchangeCodes += 1 }
            return reply(200, ["code": "code\(exchangeCodes)", "expiresInSeconds": 300])
        case ("DELETE", _): return reply(204, Data())
        case ("GET", "/launcher/api/public/assets/Windows"):
            return reply(200, games.map { ["appName": $0.appName, "buildVersion": "1.0", "catalogItemId": $0.item, "namespace": $0.namespace] })
        case ("GET", "/library/api/public/items"):
            return reply(200, ["records": games.map { ["namespace": $0.namespace, "catalogItemId": $0.item, "appName": $0.appName,
                                                        "acquisitionDate": "2026-01-02T03:04:05.000Z"] }, "responseMetadata": [:]])
        case ("POST", let path) where path.hasSuffix("/ownershipToken"):
            return reply(200, Data("ovt-bytes".utf8))
        default: break
        }
        if url.path.hasPrefix("/catalog/api/shared/namespace/") {
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "id" }!.value!
            guard let game = games.first(where: { $0.item == id }) else { return reply(200, [:] as [String: Any]) }
            var item: [String: Any] = ["id": id, "title": game.title, "description": "About \(game.title)",
                                       "keyImages": [["type": "DieselGameBoxTall", "url": "https://img.example/\(id)-tall.jpg"],
                                                     ["type": "DieselGameBox", "url": "https://img.example/\(id)-wide.jpg"]],
                                       "categories": game.categories.map { ["path": $0] },
                                       "customAttributes": game.attributes.mapValues { ["type": "STRING", "value": $0] }]
            if game.dlc { item["mainGameItem"] = ["id": "base"] }
            return reply(200, [id: item])
        }
        if url.path.hasPrefix("/launcher/api/public/assets/v2/") {
            let sha = Data(Insecure.SHA1.hash(data: manifestData)).map { String(format: "%02x", $0) }.joined()
            return reply(200, ["elements": [["appName": games.first?.appName ?? "", "buildVersion": "1.0", "hash": sha,
                                             "manifests": [["uri": "https://cdn.example/Builds/Org/app/build.manifest",
                                                            "queryParams": [["name": "f_token", "value": "t"]]]]]]])
        }
        if url.host == "cdn.example" {
            if url.path.hasSuffix(".manifest") { return reply(200, manifestData) }
            let path = url.path.replacingOccurrences(of: "/Builds/Org/app/", with: "")
            if let data = cdn[path] { return reply(200, data) }
            return reply(404, Data())
        }
        return reply(404, ["errorCode": "not_found \(url.path)"])
    }
}

final class EpicSourceTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("epic-src-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func session(expiresIn: TimeInterval = 3600) -> EpicSession {
        EpicSession(accessToken: "eg1~saved", expiresAt: Date().addingTimeInterval(expiresIn), refreshToken: "rt-1",
                    refreshExpiresAt: .distantFuture, accountID: "acct", displayName: "Couch Player")
    }
    private func source(_ server: FakeEpic, store: MemoryEpicCredentials) -> EpicSource {
        let noPause: @Sendable (Double) async throws -> Void = { _ in }
        let account = EpicAccount(store: store, auth: EpicAuth(transport: server, pause: noPause),
                                  api: EpicLibraryAPI(transport: server, pause: noPause))
        return EpicSource(account: account, cacheDirectory: root)
    }

    func testLibraryListsInstallableWindowsGamesWithArtworkAndSkipsTheRest() async throws {
        let server = FakeEpic()
        server.games = [
            .init(appName: "Sugar", item: "c1", title: "Sugar Rush"),
            .init(appName: "Marketplace", namespace: "ue", item: "c2", title: "UE Asset"),
            .init(appName: "SugarDLC", item: "c3", title: "Sugar Rush Soundtrack", dlc: true),
            .init(appName: "Mod", item: "c4", title: "A Mod", categories: ["mods"]),
            .init(appName: "EAGame", item: "c5", title: "EA Game", attributes: ["ThirdPartyManagedApp": "The EA App"]),
            .init(appName: "Apple", item: "c6", title: "Apple Tale"),
        ]
        let epic = source(server, store: MemoryEpicCredentials(session()))
        let games = try await epic.ownedGames()
        XCTAssertEqual(games.map(\.title), ["Apple Tale", "Sugar Rush"])
        let sugar = try XCTUnwrap(games.last)
        XCTAssertEqual(sugar.id, GameID(source: SourceID.epic, value: "Sugar"))
        XCTAssertEqual(sugar.coverURL?.absoluteString, "https://img.example/c1-tall.jpg")
        XCTAssertEqual(sugar.heroURL?.absoluteString, "https://img.example/c1-wide.jpg")
        XCTAssertEqual(sugar.platforms, [.windows])
        XCTAssertEqual(sugar.summary, "About Sugar Rush")
        XCTAssertNotNil(sugar.sourceAcquiredAt)
        XCTAssertEqual(server.count("GET catalog"), 5, "The ue namespace is never looked up")

        _ = try await epic.ownedGames()
        XCTAssertEqual(server.count("GET catalog"), 5, "Unchanged builds reuse the cached catalog")
        _ = try await source(server, store: MemoryEpicCredentials(session())).ownedGames()
        XCTAssertEqual(server.count("GET catalog"), 5, "The catalog cache survives relaunch")
    }

    func testExpiringSessionIsRefreshedAndSavedAndARejectedOneSignsOut() async throws {
        let server = FakeEpic()
        let store = MemoryEpicCredentials(session(expiresIn: 60))
        let epic = source(server, store: store)
        _ = try await epic.ownedGames()
        XCTAssertEqual(try store.load()?.refreshToken, "rt-2")
        XCTAssertEqual(try store.load()?.accessToken, "eg1~fresh")

        server.refreshRejected = true
        let expired = MemoryEpicCredentials(session(expiresIn: 60))
        do { _ = try await source(server, store: expired).ownedGames(); XCTFail() }
        catch { XCTAssertEqual(error as? SourceFailure, .expired) }
        XCTAssertNil(try expired.load())
        let identity = try await source(server, store: expired).auth.identity()
        XCTAssertNil(identity)
    }

    func testSignOutForgetsTheSessionEvenOffline() async throws {
        let server = FakeEpic(); server.offline = true
        let store = MemoryEpicCredentials(session())
        let epic = source(server, store: store)
        let before = try await epic.auth.identity()
        XCTAssertEqual(before?.displayName, "Couch Player")
        try await epic.auth.signOut()
        XCTAssertNil(try store.load())
        do { _ = try await epic.ownedGames(); XCTFail() } catch { XCTAssertEqual(error as? SourceFailure, .signedOut) }
    }

    func testInstallsVerifiesRepairsAndLaunchesWithFreshSignInCodes() async throws {
        let server = FakeEpic()
        server.games = [.init(appName: "Sugar", item: "c1", title: "Sugar Rush", attributes: ["AdditionalCommandLine": "-skipintro \"-name=Two Words\""])]
        server.files = ["binaries/win64/Game.exe": Data(repeating: 7, count: 300), "Content/Paks/data.pak": Data(repeating: 9, count: 500)]
        try server.publishBuild()
        let epic = source(server, store: MemoryEpicCredentials(session()))
        let owned = try await epic.ownedGames()
        let game = try XCTUnwrap(owned.first)
        let installer = try epic.installer(for: game)

        let plan = try await installer.resolve()
        XCTAssertEqual(plan.estimate.installedBytes, 800)
        XCTAssertEqual(plan.launchSpec.executableRelativePath, "Binaries/Win64/Game.exe")
        XCTAssertEqual(plan.launchSpec.arguments, ["-nosplash", "-skipintro", "-name=Two Words"])
        XCTAssertFalse(String(decoding: plan.sourcePayload, as: UTF8.self).contains("eg1~"), "Plans never hold credentials")

        let progress = LockedValues<InstallProgress>()
        try await installer.download(plan, to: root) { progress.append($0) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("binaries/win64/Game.exe")), Data(repeating: 7, count: 300))
        XCTAssertEqual(progress.values.last?.bytesCompleted, 800)
        XCTAssertEqual(progress.values.last?.bytesTotal, 800)

        let spec = try await installer.validate(plan, at: root, staging: InstallStaging())
        XCTAssertEqual(spec.executableRelativePath, "binaries/win64/Game.exe", "Launch path follows the spelling on disk")
        XCTAssertEqual(spec.workingDirectoryRelativePath, "binaries/win64")

        var result = try await installer.verifyOriginals(plan, at: root, staging: nil)
        XCTAssertTrue(result.isValid)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Content/Paks/data.pak"))
        result = try await installer.verifyOriginals(plan, at: root, staging: nil)
        XCTAssertEqual(result.invalidFiles, ["Content/Paks/data.pak"])
        try await installer.repair(plan, at: root, staging: nil) { _ in }
        result = try await installer.verifyOriginals(plan, at: root, staging: nil)
        XCTAssertTrue(result.isValid)

        let first = try await installer.prepareLaunch(spec, plan: plan, at: root, offline: false)
        let second = try await installer.prepareLaunch(spec, plan: plan, at: root, offline: false)
        XCTAssertEqual(Array(first.arguments.prefix(3)), ["-nosplash", "-skipintro", "-name=Two Words"])
        XCTAssertEqual(Array(first.arguments.dropFirst(3)), ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=code1", "-AUTH_TYPE=exchangecode", "-epicapp=Sugar",
            "-epicenv=Prod", "-EpicPortal", "-epicusername=Couch Player", "-epicuserid=acct",
            "-epiclocale=\(Locale.current.language.languageCode?.identifier ?? "en")", "-epicsandboxid=ns"])
        XCTAssertTrue(second.arguments.contains("-AUTH_PASSWORD=code2"), "Every launch gets a new code")
    }

    func testOfflineLaunchFollowsCanRunOffline() async throws {
        let server = FakeEpic()
        server.games = [.init(appName: "Online", item: "c1", title: "Online Only", attributes: ["CanRunOffline": "false"]),
                        .init(appName: "Offline", item: "c2", title: "Offline OK")]
        server.files = ["Game.exe": Data(repeating: 1, count: 10)]
        try server.publishBuild()
        let epic = source(server, store: MemoryEpicCredentials(session()))
        let games = try await epic.ownedGames()
        for game in games {
            let installer = try epic.installer(for: game)
            let plan = try await installer.resolve()
            server.offline = true
            if game.id.value == "Online" {
                do { _ = try await installer.prepareLaunch(plan.launchSpec, plan: plan, at: root, offline: false); XCTFail() }
                catch { XCTAssertEqual((error as? OperationFailure)?.reason, "Epic needs to be online to start this game.") }
            } else {
                let spec = try await installer.prepareLaunch(plan.launchSpec, plan: plan, at: root, offline: false)
                XCTAssertTrue(spec.arguments.contains("-AUTH_PASSWORD="))
            }
            server.offline = false
        }
    }

    func testOwnershipTokenIsWrittenInsideTheGameAndPassedAsAWindowsPath() async throws {
        let server = FakeEpic()
        server.games = [.init(appName: "Denuvo", item: "c1", title: "Protected", attributes: ["OwnershipToken": "true"])]
        server.files = ["Game.exe": Data(repeating: 1, count: 10)]
        try server.publishBuild()
        let epic = source(server, store: MemoryEpicCredentials(session()))
        let owned = try await epic.ownedGames()
        let installer = try epic.installer(for: try XCTUnwrap(owned.first))
        let plan = try await installer.resolve()
        let spec = try await installer.prepareLaunch(plan.launchSpec, plan: plan, at: root, offline: false)
        let token = root.appendingPathComponent(".playden-epic/nsc1.ovt")
        XCTAssertEqual(try Data(contentsOf: token), Data("ovt-bytes".utf8))
        let index = try XCTUnwrap(spec.arguments.firstIndex(of: "-EpicPortal"))
        XCTAssertEqual(spec.arguments[index - 1], "-epicovt=Z:" + token.path.replacingOccurrences(of: "/", with: "\\"))
    }

    func testExpiredSignInAtLaunchAsksToSignInAgain() async throws {
        let server = FakeEpic(); server.refreshRejected = true
        server.games = [.init(appName: "Sugar", item: "c1", title: "Sugar")]
        server.files = ["Game.exe": Data(repeating: 1, count: 10)]
        try server.publishBuild()
        let store = MemoryEpicCredentials(session())
        let epic = source(server, store: store)
        let owned = try await epic.ownedGames()
        let installer = try epic.installer(for: try XCTUnwrap(owned.first))
        let plan = try await installer.resolve()
        try store.save(session(expiresIn: 30))
        let fresh = source(server, store: store)
        do { _ = try await fresh.installer(for: plan.game).prepareLaunch(plan.launchSpec, plan: plan, at: root, offline: false); XCTFail() }
        catch { XCTAssertEqual((error as? OperationFailure)?.stage, "Sign-in expired") }
    }

    func testDeviceCodeSignInReplacesAnExpiredCodeAndSavesTheSession() async throws {
        let server = FakeEpic()
        let store = MemoryEpicCredentials()
        let epic = source(server, store: store)
        let events = LockedValues<AuthenticationEvent>()
        let identity = try await epic.auth.signInWithDeviceCode { events.append($0) }
        XCTAssertEqual(identity, SourceIdentity(sourceID: SourceID.epic, displayName: "Couch Player"))
        let codes = events.values.compactMap { event -> String? in if case .deviceCode(let code, _, _, _) = event { return code }; return nil }
        XCTAssertEqual(codes, ["CODE1", "CODE2"])
        XCTAssertTrue(events.values.contains(.expired))
        XCTAssertEqual(try store.load()?.refreshToken, "rt-new")
        XCTAssertEqual(server.count("DELETE"), 1, "The console session is ended after the trade")
    }

    func testTermsToAcceptCarryTheirPage() {
        let url = URL(string: "https://epicgames.com/continue/abc")!
        XCTAssertEqual(EpicAccount.failure(EpicError.correctiveAction(url)) as? SourceFailure, .actionRequired(url))
    }

    func testCommandLinesSplitLikeTheLauncher() {
        XCTAssertEqual(EpicInstaller.splitCommandLine(#"  -a  "-b=c d" e"#), ["-a", "-b=c d", "e"])
        XCTAssertEqual(EpicInstaller.splitCommandLine(""), [])
    }
}

private final class LockedValues<T>: @unchecked Sendable {
    private let lock = NSLock(); private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var values: [T] { lock.withLock { items } }
}
