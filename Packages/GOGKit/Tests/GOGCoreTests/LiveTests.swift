import XCTest
@testable import GOGCore

/// Against GOG's real servers; `GOG_LIVE=1 swift test --package-path Packages/GOGKit --filter LiveTests`.
/// The account tests read `.gog-session.json` from the repo root (`scripts/gog-sign-in.sh`) and write
/// the refreshed session back.
final class LiveTests: XCTestCase {
    static let sessionURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../.gog-session.json").standardizedFileURL

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GOG_LIVE"] == "1", "set GOG_LIVE=1")
    }

    /// Public: DOSBox from the dependency store, downloaded, verified, then damaged and repaired.
    func testDependencyDownloadVerifyAndRepair() async throws {
        let api = GOGAPI()
        let repository = try await api.dependencyRepository()
        let depot = try XCTUnwrap(repository.depots.first { $0.dependencyId == "DOSBox074_2CS" })
        let manifestData = try await api.manifest(at: URL(string: "https://gog-cdn-fastly.gog.com/content-system/v2/dependencies/meta/\(GOGCodec.galaxyPath(depot.manifest))")!)
        let files = try GOGDepotSelection.files(try GOGHTTP.decode(GOGDepotManifestV2.self, manifestData), product: GOGFile.dependencyStore)
        let manifest = GOGInstallManifest(generation: 2, productID: "0", buildID: "dosbox", platform: "windows", versionName: nil,
                                          installDirectory: "DOSBox", language: "en-US", products: [], dependencies: ["DOSBox074_2CS"], files: files)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gog-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = GOGCDNFetcher(manifest: manifest, accessToken: { "" })
        let downloader = GOGDownloader(destination: root)
        try await downloader.download(manifest, fetcher: fetcher)
        XCTAssertEqual(try downloader.invalidFiles(in: manifest), [])
        try Data("damaged".utf8).write(to: root.appendingPathComponent("DOSBOX/Documentation/INSTALL.txt"))
        XCTAssertEqual(try downloader.invalidFiles(in: manifest), ["DOSBOX/Documentation/INSTALL.txt"])
        try await downloader.download(manifest, only: ["DOSBOX/Documentation/INSTALL.txt"], fetcher: fetcher)
        XCTAssertEqual(try downloader.invalidFiles(in: manifest), [])
    }

    /// Account: refresh, list the library, resolve a Mac and a gen 1 Windows build, and read their launch tasks.
    func testAccountResolveAndInfoFile() async throws {
        let data = try XCTUnwrap(try? Data(contentsOf: Self.sessionURL), "run scripts/gog-sign-in.sh first")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let session = try await GOGAuth().refresh(try decoder.decode(GOGSession.self, from: data))
        try encoder.encode(session).write(to: Self.sessionURL, options: .atomic)

        let api = GOGAPI()
        let owned = Set(try await api.ownedProductIDs(accessToken: session.accessToken).map(String.init))
        XCTAssertFalse(owned.isEmpty)
        let targets = [("2116968103", "osx"), ("1425039730", "windows")].filter { owned.contains($0.0) }
        XCTAssertFalse(targets.isEmpty, "the account owns neither VirtuaVerse nor Monkey Island 2 Special Edition")
        for (product, os) in targets {
            let resolution = try await GOGResolver(api: api).resolve(productID: product, os: os, language: "english", owned: owned, accessToken: session.accessToken)
            XCTAssertGreaterThan(resolution.manifest.installedSize, 0)
            let info = try XCTUnwrap(resolution.manifest.infoFile, "\(product) has no info file")
            let fetcher = GOGCDNFetcher(manifest: resolution.manifest, accessToken: { session.accessToken })
            let tasks = try GOGInfoFile.parse(try await GOGDownloader.contents(of: info, fetcher: fetcher))
            XCTAssertNotNil(tasks.primaryTask?.path, "\(product) has no primary task")
            print("\(product) \(os): gen \(resolution.manifest.generation), \(resolution.manifest.files.count) entries, \(resolution.manifest.downloadSize / 1_000_000) MB, runs \(tasks.primaryTask?.path ?? "-")")
        }
    }
}
