import XCTest
import Domain
import EpicCore
@testable import Sources

/// Runs `EpicSource` against the real account in `.epic-session.json`. `EPIC_LIVE=1 swift test --filter EpicLiveTests`.
final class EpicLiveTests: XCTestCase {
    private var sessionURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../.epic-session.json").standardizedFileURL
    }

    func testLibraryAndInstallPlansFromTheRealAccount() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EPIC_LIVE"] == "1", "Set EPIC_LIVE=1 to talk to Epic")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sessionURL.path), "Run scripts/epic-sign-in.sh first")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let store = MemoryEpicCredentials(try decoder.decode(EpicSession.self, from: Data(contentsOf: sessionURL)))
        defer {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .prettyPrinted
            if let session = try? store.load(), let data = try? encoder.encode(session) { try? data.write(to: sessionURL) }
        }
        let source = EpicSource(account: EpicAccount(store: store))
        let games = try await source.ownedGames()
        XCTAssertFalse(games.isEmpty)
        print("EPIC-LIVE library: \(games.count) games")
        var resolved = 0
        let resolveCount = Int(ProcessInfo.processInfo.environment["EPIC_LIVE_RESOLVE"] ?? "40") ?? 40
        for game in games.prefix(resolveCount) {
            do {
                let plan = try await source.installer(for: game).resolve()
                let payload = try JSONDecoder().decode(EpicPlanPayload.self, from: plan.sourcePayload)
                print("EPIC-LIVE \(game.id.value) | \(game.title) | \(plan.estimate.downloadBytes / 1_000_000) MB | exe=\(plan.launchSpec.executableRelativePath) | offline=\(payload.canRunOffline) ovt=\(payload.requiresOwnershipToken) deploy=\(payload.deploymentID != nil) cover=\(game.coverURL != nil)")
                resolved += 1
            } catch { print("EPIC-LIVE \(game.id.value) | \(game.title) | FAILED \(error)") }
        }
        if resolveCount > 0 { XCTAssertGreaterThan(resolved, 0) }

        // EPIC_LIVE_INSTALL=<app name>: download, verify and prepare a real launch, then delete the files.
        guard let appName = ProcessInfo.processInfo.environment["EPIC_LIVE_INSTALL"], let game = games.first(where: { $0.id.value == appName }) else { return }
        let installer = try source.installer(for: game)
        let plan = try await installer.resolve()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("epic-live-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = Date()
        try await installer.download(plan, to: directory) { _ in }
        print("EPIC-LIVE installed \(game.title) in \(Int(Date().timeIntervalSince(started))) s")
        let verification = try await installer.verifyOriginals(plan, at: directory, staging: nil)
        XCTAssertTrue(verification.isValid, "\(verification.invalidFiles)")
        let spec = try await installer.validate(plan, at: directory, staging: InstallStaging())
        let launch = try await installer.prepareLaunch(spec, plan: plan, at: directory, offline: false)
        let code = launch.arguments.first { $0.hasPrefix("-AUTH_PASSWORD=") }?.dropFirst("-AUTH_PASSWORD=".count) ?? ""
        XCTAssertEqual(code.count, 32)
        print("EPIC-LIVE launch \(spec.executableRelativePath) with \(launch.arguments.count) arguments")
    }
}
