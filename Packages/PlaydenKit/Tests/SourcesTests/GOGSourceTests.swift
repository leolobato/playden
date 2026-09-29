import XCTest
import CryptoKit
import zlib
import Domain
import GOGCore
@testable import Sources

private func deflated(_ data: Data) -> Data {
    var length = uLongf(compressBound(uLong(data.count)))
    var out = Data(count: Int(length))
    _ = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { i in
        compress(o.bindMemory(to: Bytef.self).baseAddress, &length, i.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
    } }
    out.count = Int(length)
    return out
}
private func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// GOG's auth, embed, gamesdb, content-system and CDN, in memory.
private final class FakeGOG: GOGTransport, @unchecked Sendable {
    struct Game { var id: String; var title: String; var type = "game"; var visible = true; var systems = ["windows"] }
    private let lock = NSLock()
    var games: [Game] = []
    var owned: [String] = []
    /// Per platform: install path -> content, one chunk per file.
    var files: [String: [String: Data]] = [:]
    var tasks: [String: String] = [:]   // platform -> playTasks JSON
    var buildID = "b1"
    var refreshRejected = false
    var chunks: [String: Data] = [:]
    private(set) var log: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        lock.withLock { log.append(url.host! + url.path) }
        func reply(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        func json(_ object: Any) -> (Data, HTTPURLResponse) { reply(200, try! JSONSerialization.data(withJSONObject: object)) }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        switch (url.host!, url.path) {
        case ("auth.gog.com", "/token"):
            if query["grant_type"] == "authorization_code" {
                guard query["code"] == "good" else { return reply(400, Data(#"{"error":"invalid_grant","error_description":"Code doesn't exist"}"#.utf8)) }
                return json(["access_token": "A1", "expires_in": 3600, "refresh_token": "R1", "user_id": "42"])
            }
            if refreshRejected { return reply(400, Data(#"{"error":"invalid_grant","error_description":"invalid"}"#.utf8)) }
            return json(["access_token": "A2", "expires_in": 3600, "refresh_token": "R2", "user_id": "42"])
        case ("embed.gog.com", "/userData.json"): return json(["username": "couch"])
        case ("embed.gog.com", "/user/data/games"): return json(["owned": owned.compactMap(Int.init)])
        case ("api.gog.com", let path) where path.hasPrefix("/v2/games/"):
            return json(["_links": ["logo": ["href": "https://images.gog-statics.com/logo.png"]]])
        case ("gamesdb.gog.com", let path):
            let id = String(path.split(separator: "/").last!)
            guard let game = games.first(where: { $0.id == id }) else { return reply(404, Data()) }
            return json(["type": game.type, "title": ["*": game.title],
                         "supported_operating_systems": game.systems.map { ["slug": $0] },
                         "game": ["visible_in_library": game.visible, "genres": [["name": ["*": "Adventure"]]],
                                  "vertical_cover": ["url_format": "https://images.gog.com/c{formatter}.{ext}?namespace=gamesdb"],
                                  "background": ["url_format": "https://images.gog.com/h{formatter}.{ext}?namespace=gamesdb"]]])
        case ("content-system.gog.com", let path) where path.hasSuffix("/builds"):
            let os = path.split(separator: "/")[3]
            guard files[String(os)] != nil else { return json(["items": []]) }
            return json(["items": [["build_id": buildID, "product_id": "1", "os": os, "branch": NSNull(), "generation": 2,
                                    "urls": [["endpoint_name": "fastly", "url": "https://cdn.test/content-system/v2/meta/aa/bb/\(os)", "url_format": "",
                                              "parameters": [:], "priority": 10]]]]])
        case ("content-system.gog.com", let path) where path.hasSuffix("/secure_link"):
            return json(["urls": [["endpoint_name": "fastly", "url_format": "{base_url}{path}", "parameters": ["base_url": "https://cdn.test", "path": "/store"], "priority": 10]]])
        case ("cdn.test", let path) where path.hasPrefix("/content-system/v2/meta/aa/bb/"):
            let os = String(path.split(separator: "/").last!)
            let meta: [String: Any] = ["baseProductId": "1", "buildId": buildID, "installDirectory": "Couch Game", "platform": os,
                                       "products": [["productId": "1"]], "depots": [["productId": "1", "languages": ["*"], "manifest": "depot\(os)"]]]
            return reply(200, deflated(try! JSONSerialization.data(withJSONObject: meta)))
        case ("cdn.test", let path) where path.contains("/meta/de/po/depot"):
            let os = String(path.dropFirst(path.range(of: "depot")!.upperBound.utf16Offset(in: path)))
            return reply(200, deflated(depotManifest(os)))
        case ("cdn.test", let path) where path.hasPrefix("/store/"):
            let hash = String(path.split(separator: "/").last!)
            return reply(200, lock.withLock { chunks[hash] } ?? Data())
        default:
            return reply(404, Data())
        }
    }

    private func depotManifest(_ os: String) -> Data {
        var items: [[String: Any]] = []
        var all = files[os] ?? [:]
        all[os == "osx" ? "Contents/Resources/goggame-1.info" : "goggame-1.info"] = Data((tasks[os] ?? "{}").utf8)
        for (path, content) in all.sorted(by: { $0.key < $1.key }) {
            let compressed = deflated(content)
            lock.withLock { chunks[md5(compressed)] = compressed }
            var item: [String: Any] = ["type": "DepotFile", "path": path.replacingOccurrences(of: "/", with: "\\"),
                                       "chunks": [["md5": md5(content), "compressedMd5": md5(compressed), "size": content.count, "compressedSize": compressed.count]]]
            if path.contains("MacOS/"), !path.hasSuffix("helper") { item["flags"] = ["executable"] }
            items.append(item)
        }
        return try! JSONSerialization.data(withJSONObject: ["version": 2, "depot": ["items": items]])
    }
}

final class GOGSourceTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("gog-source-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func source(_ fake: FakeGOG, session: GOGSession? = GOGSession(accessToken: "A0", expiresAt: .now.addingTimeInterval(3600),
                                                                              refreshToken: "R0", userID: "42", displayName: "couch")) -> (GOGSource, MemoryGOGCredentials) {
        let store = MemoryGOGCredentials(session)
        let account = GOGAccount(store: store, auth: GOGAuth(transport: fake, pause: { _ in }), api: GOGAPI(transport: fake, pause: { _ in }))
        return (GOGSource(account: account), store)
    }

    func testWebLoginSignsInWithThePastedAddress() async throws {
        let fake = FakeGOG()
        let (source, store) = source(fake, session: nil)
        let identity = try await source.auth.identity()
        XCTAssertNil(identity)
        XCTAssertEqual(source.capabilities.account, .webLogin)
        XCTAssertEqual(source.auth.webLoginURL()?.host, "auth.gog.com")
        XCTAssertTrue(source.auth.redirectMatches(URL(string: "https://embed.gog.com/on_login_success?origin=client&code=x")!))
        XCTAssertFalse(source.auth.redirectMatches(URL(string: "https://www.gog.com/")!))
        do { _ = try await source.auth.signIn(withRedirect: "https://embed.gog.com/on_login_success?origin=client&code=bad"); XCTFail() }
        catch { XCTAssertEqual(error as? SourceFailure, .credentialsRejected) }
        do { _ = try await source.auth.signIn(withRedirect: "https://embed.gog.com/on_login_success?origin=client"); XCTFail() }
        catch { XCTAssertEqual(error as? SourceFailure, .credentialsRejected) }
        let signedIn = try await source.auth.signIn(withRedirect: "https://embed.gog.com/on_login_success?origin=client&code=good")
        XCTAssertEqual(signedIn, SourceIdentity(sourceID: SourceID.gog, displayName: "couch"))
        XCTAssertEqual(try store.load()?.refreshToken, "R1")
        try await source.auth.signOut()
        XCTAssertNil(try store.load())
    }

    func testRejectedRefreshSignsOut() async throws {
        let fake = FakeGOG(); fake.refreshRejected = true; fake.owned = ["1"]
        let (source, store) = source(fake, session: GOGSession(accessToken: "A0", expiresAt: .now, refreshToken: "R0", userID: "42"))
        do { _ = try await source.ownedGames(); XCTFail() }
        catch { XCTAssertEqual(error as? SourceFailure, .expired) }
        XCTAssertNil(try store.load())
    }

    func testRefreshStoresTheNewToken() async throws {
        let fake = FakeGOG(); fake.owned = []
        let (source, store) = source(fake, session: GOGSession(accessToken: "A0", expiresAt: .now.addingTimeInterval(60), refreshToken: "R0", userID: "42", displayName: "couch"))
        _ = try await source.ownedGames()
        XCTAssertEqual(try store.load()?.refreshToken, "R2")
        XCTAssertEqual(try store.load()?.displayName, "couch")
    }

    func testLibraryKeepsVisibleGamesWithABuildPlaydenCanRun() async throws {
        let fake = FakeGOG()
        fake.games = [
            .init(id: "1", title: "Zeta", systems: ["windows", "osx"]), .init(id: "2", title: "Alpha"),
            .init(id: "3", title: "Pack", type: "spam", visible: false), .init(id: "4", title: "DLC", type: "dlc"),
            .init(id: "5", title: "Penguin", systems: ["linux"]), .init(id: "6", title: "Hidden", visible: false),
        ]
        fake.owned = ["1", "2", "3", "4", "5", "6", "7"]
        let (source, _) = source(fake)
        let games = try await source.ownedGames()
        XCTAssertEqual(games.map(\.title), ["Alpha", "Zeta"])
        XCTAssertEqual(games[1].platforms, [.windows, .macOS])
        XCTAssertEqual(games[0].platforms, [.windows])
        XCTAssertEqual(games[1].genres, ["Adventure"])
        XCTAssertEqual(games[1].coverURL?.absoluteString, "https://images.gog.com/c.jpg?namespace=gamesdb")
        XCTAssertEqual(games[1].heroURL?.absoluteString, "https://images.gog.com/h.jpg?namespace=gamesdb")
        XCTAssertEqual(games[1].logoURL?.absoluteString, "https://images.gog-statics.com/logo.png")
    }

    private func windowsGame(_ fake: FakeGOG) {
        fake.owned = ["1"]
        fake.games = [.init(id: "1", title: "Couch Game")]
        fake.files["windows"] = ["Bin/Game.exe": Data("MZ game".utf8), "Bin/Tool.exe": Data("MZ tool".utf8), "data/level.pak": Data(repeating: 3, count: 5000)]
        fake.tasks["windows"] = #"{"playTasks":[{"category":"game","isPrimary":true,"path":"Bin\\Game.exe","arguments":"-windowed \"two words\"","type":"FileTask"},{"category":"tool","name":"Settings","path":"Bin/Tool.exe","type":"FileTask"},{"category":"document","path":"Manual.pdf","type":"FileTask"},{"link":"https://www.gog.com/support","type":"URLTask"}]}"#
    }

    func testWindowsInstallResolvesDownloadsVerifiesAndRepairs() async throws {
        let fake = FakeGOG(); windowsGame(fake)
        let (source, _) = source(fake)
        let game = try await source.ownedGames()[0]
        let installer = try source.installer(for: game)
        let plan = try await installer.resolve()
        XCTAssertEqual(plan.platform, .windows)
        XCTAssertEqual(plan.launchSpec.executableRelativePath, "Bin/Game.exe")
        XCTAssertEqual(plan.launchSpec.workingDirectoryRelativePath, "Bin")
        XCTAssertEqual(plan.launchSpec.arguments, ["-windowed", "two words"])
        XCTAssertEqual(plan.launchOptions?.map(\.title), ["Settings"])
        XCTAssertEqual(plan.manifestIDs, ["build": "b1"])
        XCTAssertGreaterThan(plan.estimate.installedBytes, 5000)
        XCTAssertFalse(String(decoding: plan.sourcePayload, as: UTF8.self).contains("A0"), "no tokens in the plan")

        let progress = ProgressLog()
        try await installer.download(plan, to: root) { progress.add($0) }
        XCTAssertEqual(progress.last?.bytesCompleted, progress.last?.bytesTotal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".playden-gog/install.json").path))
        let valid1 = try await installer.verifyOriginals(plan, at: root, staging: nil).isValid; XCTAssertTrue(valid1)
        let spec = try await installer.validate(plan, at: root, staging: InstallStaging())
        XCTAssertEqual(spec.executableRelativePath, "Bin/Game.exe")

        try Data("broken".utf8).write(to: root.appendingPathComponent("data/level.pak"))
        let invalid = try await installer.verifyOriginals(plan, at: root, staging: nil).invalidFiles; XCTAssertEqual(invalid, ["data/level.pak"])
        try await installer.repair(plan, at: root, staging: nil) { _ in }
        let valid2 = try await installer.verifyOriginals(plan, at: root, staging: nil).isValid; XCTAssertTrue(valid2)
        let prepared = try await installer.prepareLaunch(spec, plan: plan, at: root, offline: true)
        XCTAssertEqual(prepared, spec, "GOG games need nothing per launch, even offline")
    }

    func testInstallScriptSetsTheINIAndVerifyAcceptsIt() async throws {
        let fake = FakeGOG(); windowsGame(fake)
        fake.files["windows"]?["game.ini"] = Data("[game]\r\ngameid=sky\r\n".utf8)
        fake.files["windows"]?["goggame-1.script"] = Data(#"{"actions":[{"install":{"action":"setIni","arguments":{"filename":"{app}\\game.ini","keyName":"path","keyValue":"{app}","section":"game"}},"languages":["*"]},{"install":{"action":"supportData","arguments":{"target":"{app}/saves","type":"folder"}},"languages":["*"]}]}"#.utf8)
        let (source, _) = source(fake)
        let installer = try source.installer(for: try await source.ownedGames()[0])
        let plan = try await installer.resolve()
        try await installer.download(plan, to: root) { _ in }
        _ = try await installer.postInstall(plan, at: root)
        let ini = try String(contentsOf: root.appendingPathComponent("game.ini"), encoding: .isoLatin1)
        XCTAssertTrue(ini.contains("path=Z:" + root.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")), ini)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("saves").path))
        let verification = try await installer.verifyOriginals(plan, at: root, staging: nil)
        XCTAssertTrue(verification.isValid, "\(verification.invalidFiles)")
    }

    func testDownloadRefusesANewerBuild() async throws {
        let fake = FakeGOG(); windowsGame(fake)
        let (source, _) = source(fake)
        let installer = try source.installer(for: try await source.ownedGames()[0])
        let plan = try await installer.resolve()
        fake.buildID = "b2"
        do { try await installer.download(plan, to: root) { _ in }; XCTFail() }
        catch let failure as OperationFailure { XCTAssertTrue(failure.reason.contains("newer version")) }
    }

    func testValidateMatchesCaseAndReportsAMissingProgram() async throws {
        let fake = FakeGOG(); windowsGame(fake)
        fake.tasks["windows"] = #"{"playTasks":[{"isPrimary":true,"path":"BIN/game.EXE","type":"FileTask"}]}"#
        let (source, _) = source(fake)
        let installer = try source.installer(for: try await source.ownedGames()[0])
        let plan = try await installer.resolve()
        try await installer.download(plan, to: root) { _ in }
        let spec = try await installer.validate(plan, at: root, staging: InstallStaging())
        XCTAssertEqual(spec.executableRelativePath, "Bin/Game.exe")
        XCTAssertEqual(spec.workingDirectoryRelativePath, "Bin")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Bin/Game.exe"))
        do { _ = try await installer.validate(plan, at: root, staging: InstallStaging()); XCTFail() }
        catch let failure as OperationFailure { XCTAssertTrue(failure.reason.contains("missing")) }
    }

    func testMacBuildInstallsAsTheAppBundle() async throws {
        let fake = FakeGOG(); windowsGame(fake)
        fake.games = [.init(id: "1", title: "Couch Game", systems: ["windows", "osx"])]
        fake.files["osx"] = macBundle(Self.arm64)
        fake.tasks["osx"] = #"{"playTasks":[{"category":"game","isPrimary":true,"path":"Contents/MacOS/Couch","type":"FileTask"}]}"#
        let (source, _) = source(fake)
        let installer = try source.installer(for: try await source.ownedGames()[0])
        let plan = try await installer.resolve(platform: .macOS)
        XCTAssertEqual(plan.platform, .macOS)
        XCTAssertEqual(plan.launchSpec.executableRelativePath, "Couch Game.app")
        try await installer.download(plan, to: root) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Couch Game.app/Contents/Resources/goggame-1.info").path))
        _ = try await installer.postInstall(plan, at: root)
        let helper = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Couch Game.app/Contents/MacOS/helper").path)[.posixPermissions] as? Int
        XCTAssertEqual(helper, 0o755, "programs in Contents/MacOS run even without the flag")
        let spec = try await installer.validate(plan, at: root, staging: InstallStaging())
        XCTAssertEqual(spec.executableRelativePath, "Couch Game.app")
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Couch Game.app/Contents/MacOS/Couch").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
        let valid3 = try await installer.verifyOriginals(plan, at: root, staging: nil).isValid; XCTAssertTrue(valid3)
    }

    static let arm64 = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 24))
    static let i386 = Data([0xCE, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 24))
    /// Universal with i386 and ppc slices only.
    static let fat32 = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2, 0, 0, 0, 7] + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 18] + [UInt8](repeating: 0, count: 16))

    private func macBundle(_ executable: Data) -> [String: Data] {
        let plist = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Couch"], format: .xml, options: 0)
        return ["Contents/Info.plist": plist, "Contents/MacOS/Couch": executable, "Contents/MacOS/helper": Data("#!/bin/sh".utf8)]
    }

    func testThirtyTwoBitMacBuildSaysToUseWindows() async throws {
        let fake = FakeGOG(); windowsGame(fake)
        fake.games = [.init(id: "1", title: "Couch Game", systems: ["windows", "osx"])]
        fake.files["osx"] = macBundle(Self.i386)
        fake.tasks["osx"] = #"{"playTasks":[{"isPrimary":true,"path":"Contents/MacOS/Couch","type":"FileTask"}]}"#
        let (source, _) = source(fake)
        let installer = try source.installer(for: try await source.ownedGames()[0])
        let plan = try await installer.resolve(platform: .macOS)
        try await installer.download(plan, to: root) { _ in }
        _ = try await installer.postInstall(plan, at: root)
        do { _ = try await installer.validate(plan, at: root, staging: InstallStaging()); XCTFail() }
        catch let failure as OperationFailure { XCTAssertEqual(failure.reason, "This Mac version is 32-bit and can't run on this macOS. Switch to the Windows version.") }
    }

    func testMachOBitness() throws {
        let folder = root.appendingPathComponent("macho")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data, expected) in [("a", Self.arm64, GOGInstaller.Bitness.has64), ("b", Self.i386, .only32), ("c", Self.fat32, .only32),
                                       ("d", Data("#!/bin/sh\n".utf8), .notMachO)] {
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            XCTAssertEqual(GOGInstaller.machOBitness(url), expected, name)
        }
    }

    func testNoMacBuildSaysSo() async throws {
        let fake = FakeGOG(); windowsGame(fake)
        let (source, _) = source(fake)
        let installer = try source.installer(for: try await source.ownedGames()[0])
        do { _ = try await installer.resolve(platform: .macOS); XCTFail() }
        catch let failure as OperationFailure { XCTAssertEqual(failure.reason, "GOG has no Mac build of this game.") }
    }

    func testUnownedGameIsDenied() async throws {
        let fake = FakeGOG(); windowsGame(fake); fake.owned = []
        let (source, _) = source(fake)
        let installer = try source.installer(for: SourceGameRecord(id: GameID(source: SourceID.gog, value: "1"), title: "Couch Game"))
        do { _ = try await installer.resolve(); XCTFail() }
        catch { XCTAssertEqual(error as? SourceFailure, .accessDenied) }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [InstallProgress] = []
    func add(_ item: InstallProgress) { lock.withLock { items.append(item) } }
    var last: InstallProgress? { lock.withLock { items.max { ($0.sequence ?? 0) < ($1.sequence ?? 0) } } }
}
