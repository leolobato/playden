import XCTest
import Domain
import GOGCore
@testable import Sources

/// Runs `GOGSource` against the real account in `.gog-session.json`. `GOG_LIVE=1 swift test --filter GOGLiveTests`.
final class GOGLiveTests: XCTestCase {
    private var sessionURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../.gog-session.json").standardizedFileURL
    }

    func testLibraryAndInstallPlansFromTheRealAccount() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GOG_LIVE"] == "1", "Set GOG_LIVE=1 to talk to GOG")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sessionURL.path), "Run scripts/gog-sign-in.sh first")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let store = MemoryGOGCredentials(try decoder.decode(GOGSession.self, from: Data(contentsOf: sessionURL)))
        defer {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let session = try? store.load(), let data = try? encoder.encode(session) { try? data.write(to: sessionURL) }
        }
        let source = GOGSource(account: GOGAccount(store: store))
        let games = try await source.ownedGames()
        XCTAssertFalse(games.isEmpty)
        print("GOG-LIVE library: \(games.count) games")
        var resolved = 0
        let resolveCount = Int(ProcessInfo.processInfo.environment["GOG_LIVE_RESOLVE"] ?? "40") ?? 40
        for game in games.prefix(resolveCount) {
            for platform in game.availablePlatforms {
                do {
                    let plan = try await source.installer(for: game).resolve(platform: platform)
                    let payload = try JSONDecoder().decode(GOGPlanPayload.self, from: plan.sourcePayload)
                    print("GOG-LIVE \(game.id.value) | \(game.title) | \(platform.title) gen\(payload.generation) | \(plan.estimate.downloadBytes / 1_000_000) MB | exe=\(plan.launchSpec.executableRelativePath) args=\(plan.launchSpec.arguments) | deps=\(payload.dependencies) | options=\(plan.launchOptions?.map(\.title) ?? [])")
                    resolved += 1
                } catch { print("GOG-LIVE \(game.id.value) | \(game.title) | \(platform.title) FAILED \(error)") }
            }
        }
        if resolveCount > 0 { XCTAssertGreaterThan(resolved, 0) }

        // GOG_LIVE_INSTALL=<product id>[:osx]: download, verify and validate, then delete the files.
        guard let target = ProcessInfo.processInfo.environment["GOG_LIVE_INSTALL"] else { return }
        let parts = target.split(separator: ":").map(String.init)
        guard let game = games.first(where: { $0.id.value == parts[0] }) else { return XCTFail("\(parts[0]) is not in the library") }
        let platform: GamePlatform = parts.count > 1 && parts[1] == "osx" ? .macOS : .windows
        let installer = try source.installer(for: game)
        let plan = try await installer.resolve(platform: platform)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gog-live-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = Date()
        try await installer.download(plan, to: directory) { _ in }
        print("GOG-LIVE installed \(game.title) in \(Int(Date().timeIntervalSince(started))) s")
        let verification = try await installer.verifyOriginals(plan, at: directory, staging: nil)
        XCTAssertTrue(verification.isValid, "\(verification.invalidFiles)")
        let spec = try await installer.validate(plan, at: directory, staging: InstallStaging())
        print("GOG-LIVE launch \(spec.executableRelativePath) in \(spec.workingDirectoryRelativePath)")
    }
}
