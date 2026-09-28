import XCTest
@testable import EpicCore

/// Talks to Epic's production servers. Run with `EPIC_LIVE=1 swift test --filter LiveTests`.
/// The account tests also need `.epic-session.json` from `scripts/epic-sign-in.sh` in the repo root.
final class LiveTests: XCTestCase {
    private static let overlay = (app: "98bc04bc842e4906993fd6d6644ffb8d", namespace: "302e5ede476149b1bc3e4fe6ae45e50e",
                                  item: "cc15684f44d849e89e9bf4cec0508b68")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EPIC_LIVE"] == "1", "Set EPIC_LIVE=1 to talk to Epic")
    }

    private var sessionURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../.epic-session.json").standardizedFileURL
    }

    func testDownloadsAndVerifiesPublicOverlayFilesFromTheRealCDN() async throws {
        let token = try await EpicAuth().clientToken()
        let api = EpicLibraryAPI()
        let location = try await api.manifestLocation(platform: .windows, namespace: Self.overlay.namespace,
                                                      catalogItemID: Self.overlay.item, appName: Self.overlay.app, accessToken: token)
        let (manifest, _) = try await api.manifest(at: location)
        let small = Set(manifest.files.filter { $0.fileSize > 0 }.sorted { $0.fileSize < $1.fileSize }.prefix(4).map(\.filename))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epic-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = EpicChunkFetcher(baseURLs: location.baseURLs)
        try await EpicDownloader(destination: root).download(manifest, secrets: location.secrets, only: small, fetch: fetcher.fetch)
        let subset = EpicManifest(version: manifest.version, meta: manifest.meta, chunks: manifest.chunks,
                                  files: manifest.files.filter { small.contains($0.filename) }, customFields: [:])
        XCTAssertTrue(try EpicDownloader(destination: root).invalidFiles(in: subset).isEmpty)
    }

    func testSavedSessionListsLibraryAndCreatesLaunchCode() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sessionURL.path), "Run scripts/epic-sign-in.sh first")
        let data = try Data(contentsOf: sessionURL)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .prettyPrinted
        let auth = EpicAuth()
        let session = try await auth.refresh(try decoder.decode(EpicSession.self, from: data))
        try encoder.encode(session).write(to: sessionURL) // refresh tokens rotate
        let api = EpicLibraryAPI()
        let assets = try await api.assets(platform: .windows, accessToken: session.accessToken)
        XCTAssertFalse(assets.isEmpty)
        let library = try await api.libraryItems(accessToken: session.accessToken)
        XCTAssertFalse(library.isEmpty)
        let code = try await auth.exchangeCode(accessToken: session.accessToken)
        XCTAssertEqual(code.count, 32)
        if let game = assets.first(where: { $0.namespace != "ue" }) {
            let item = try await api.catalogItem(namespace: game.namespace, catalogItemID: game.catalogItemId, accessToken: session.accessToken)
            XCTAssertNotNil(item?.title)
        }
    }
}
