import XCTest
import Domain
@testable import Sources

final class LocalSourceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func app(_ path: String, name: String? = nil, id: String? = "com.example.game", executable: String = "Game",
                     category: String? = nil, unity: Bool = false, steam: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(path)
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleExecutable": executable, "CFBundlePackageType": "APPL"]
        if let id { plist["CFBundleIdentifier"] = id }
        if let name { plist["CFBundleName"] = name }
        if let category { plist["LSApplicationCategoryType"] = category }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: contents.appendingPathComponent("MacOS/" + executable))
        if unity || steam { try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks"), withIntermediateDirectories: true) }
        if unity { try Data().write(to: contents.appendingPathComponent("Frameworks/UnityPlayer.dylib")) }
        if steam { try Data().write(to: contents.appendingPathComponent("Frameworks/libsteam_api.dylib")) }
        return url
    }
    private func source(suggestions: [URL] = []) -> LocalSource {
        LocalSource(store: LocalLibraryStore(file: root.appendingPathComponent("support/local-games.json")), suggestionRoots: suggestions)
    }

    func testAddedAppBecomesAnAvailableNativeExternalInstall() async throws {
        let url = try app("Apps/Tunic.app", name: "TUNIC", steam: true)
        let local = source()
        let id = try await local.add(url)
        let games = try await local.ownedGames()
        XCTAssertEqual(games.map(\.title), ["TUNIC"]); XCTAssertEqual(games.first?.id, id)
        XCTAssertEqual(games.first?.availablePlatforms, [.macOS])
        let installValue = try await local.externalInstallations(for: games).first
        let install = try XCTUnwrap(installValue)
        XCTAssertTrue(install.isExternal); XCTAssertEqual(install.runtimeBinding, .native)
        XCTAssertEqual(install.external?.availability, .available); XCTAssertEqual(install.external?.usesSteam, true)
        XCTAssertEqual(install.launchSpec.executableRelativePath, "Tunic.app")
        let located = try await local.locate(install)
        XCTAssertEqual(LocalSource.realPath(located), LocalSource.realPath(url))
        let again = try await local.add(url)
        XCTAssertEqual(again, id, "Adding the same app twice keeps one entry")
        let value1 = try await local.ownedGames().count
        XCTAssertEqual(value1, 1)
    }

    func testWatchedFoldersFindAppsTwoLevelsDownButNotHelpers() async throws {
        try app("Library/Direct.app", id: "a.direct")
        try app("Library/Nested/Nested.app", id: "a.nested")
        try app("Library/Nested/Nested.app/Contents/Helpers/Helper.app", id: "a.helper")
        try app("Library/a/b/TooDeep.app", id: "a.deep")
        let local = source()
        try await local.addFolder(root.appendingPathComponent("Library"))
        let titles = try await local.ownedGames().map(\.title).sorted()
        XCTAssertEqual(titles, ["Direct", "Nested"])
        let value2 = try await local.folders().first?.gameCount
        XCTAssertEqual(value2, 2)
    }

    func testMovedAppsKeepTheirIdentityAndMissingAppsAreReported() async throws {
        let url = try app("Apps/Game.app")
        let local = source()
        let id = try await local.add(url)
        let moved = root.appendingPathComponent("Moved/Renamed.app")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: moved)
        let games = try await local.ownedGames()
        XCTAssertEqual(games.first?.id, id)
        let installValue = try await local.externalInstallations(for: games).first
        let install = try XCTUnwrap(installValue)
        XCTAssertEqual(install.launchSpec.executableRelativePath, "Renamed.app")
        try FileManager.default.removeItem(at: moved)
        let remaining = try await local.ownedGames()
        let goneValue = try await local.externalInstallations(for: remaining).first
        let gone = try XCTUnwrap(goneValue)
        XCTAssertEqual(gone.external?.availability, .missing)
        do { _ = try await local.locate(gone); XCTFail("A missing app cannot be located") } catch ExternalLocationFailure.missing {}
    }

    func testSharedEngineBundleIdentifiersDoNotMergeDifferentGames() async throws {
        let first = try app("Apps/One.app", id: "com.unity3d.player", executable: "One", unity: true)
        let second = try app("Apps/Two.app", id: "com.unity3d.player", executable: "Two", unity: true)
        let local = source()
        let one = try await local.add(first), two = try await local.add(second)
        XCTAssertNotEqual(one, two)
        let value3 = try await local.ownedGames().count
        XCTAssertEqual(value3, 2)
    }

    func testRemovedGamesStayOutOfFoldersAndComeBackWithTheirIdentity() async throws {
        let url = try app("Library/Game.app")
        let local = source()
        try await local.addFolder(root.appendingPathComponent("Library"))
        let idValue = try await local.ownedGames().first?.id
        let id = try XCTUnwrap(idValue)
        try await local.remove(id)
        let value4 = try await local.ownedGames().isEmpty
        XCTAssertTrue(value4, "A watched folder skips a removed app")
        let restored = try await local.add(url)
        XCTAssertEqual(restored, id, "Adding it again restores the same game, and so its playtime")
        let value5 = try await local.ownedGames().map(\.id)
        XCTAssertEqual(value5, [id])
    }

    func testRemovedFolderGamesAreListedAndRestoreAsFolderGames() async throws {
        let url = try app("Library/Kept.app", name: "Kept", id: "a.kept")
        let local = source()
        try await local.addFolder(root.appendingPathComponent("Library"))
        let owned = try await local.ownedGames()
        let id = try XCTUnwrap(owned.first?.id)
        try await local.remove(id)
        var removed = try await local.removedGames()
        XCTAssertEqual(removed.map(\.title), ["Kept"]); XCTAssertEqual(removed.first?.id, id); XCTAssertEqual(removed.first?.found, true)
        let restored = try await local.restore(id)
        XCTAssertEqual(restored, id, "Restoring keeps the identity, so playtime returns")
        removed = try await local.removedGames(); XCTAssertTrue(removed.isEmpty)
        let summary = try await local.folders().first
        XCTAssertEqual(summary?.gameCount, 1, "The game counts as a folder game again")

        // An app added by hand from inside a watched folder is a folder game too.
        try await local.remove(id)
        let again = try await local.add(url)
        XCTAssertEqual(again, id)
        let counted = try await local.folders().first?.gameCount
        XCTAssertEqual(counted, 1)
    }

    func testRestoreFindsMovedAppsInWatchedFoldersAndReportsLostOnes() async throws {
        let url = try app("Library/Moved.app", id: "a.moved", executable: "Moved")
        let lost = try app("Elsewhere/Lost.app", id: "a.lost", executable: "Lost")
        let local = source()
        try await local.addFolder(root.appendingPathComponent("Library"))
        let moved = try await local.add(url), gone = try await local.add(lost)
        try await local.remove(moved); try await local.remove(gone)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Sub"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("Library/Sub/Moved.app"))
        try FileManager.default.removeItem(at: lost)
        let found = try await local.removedGames().map(\.found)
        XCTAssertEqual(Set(found), [true, false])
        try await local.restore(moved)
        let titles = try await local.ownedGames().map(\.title)
        XCTAssertEqual(titles, ["Moved"])
        do { try await local.restore(gone); XCTFail("A lost app can't be restored") } catch {}
        let stillRemoved = try await local.removedGames().map(\.id)
        XCTAssertEqual(stillRemoved, [gone], "A failed restore keeps the game in the removed list")
    }

    func testRemovingAFolderCanKeepOrRemoveItsGames() async throws {
        try app("Library/Game.app")
        let local = source()
        try await local.addFolder(root.appendingPathComponent("Library"))
        _ = try await local.ownedGames()
        let folderValue = try await local.folders().first
        let folder = try XCTUnwrap(folderValue)
        try await local.removeFolder(folder.id, removingGames: false)
        let value6 = try await local.ownedGames().count
        XCTAssertEqual(value6, 1, "Kept games become manual entries")
        try await local.addFolder(root.appendingPathComponent("Library"))
        let againValue = try await local.folders().first
        let again = try XCTUnwrap(againValue)
        try await local.removeFolder(again.id, removingGames: true)
        let value7 = try await local.ownedGames().count
        XCTAssertEqual(value7, 1, "Manual entries are not removed with a folder")
    }

    func testSuggestionsListOnlyGameLikeAppsAndMarkAddedOnes() async throws {
        let game = try app("Suggested/Puzzle.app", id: "s.puzzle", category: "public.app-category.puzzle-games")
        try app("Suggested/Engine.app", id: "s.engine", unity: true)
        try app("Suggested/Editor.app", id: "s.editor", category: "public.app-category.developer-tools")
        let local = source(suggestions: [root.appendingPathComponent("Suggested")])
        try await local.add(game)
        let suggestions = try await local.suggestions()
        XCTAssertEqual(suggestions.map(\.app.title), ["Engine", "Puzzle"])
        XCTAssertEqual(suggestions.map(\.added), [false, true])
        XCTAssertEqual(suggestions.first?.app.engine, "Unity")
    }

    func testRelocateKeepsIdentityAndRefusesDuplicates() async throws {
        let url = try app("Apps/Game.app", id: "r.game")
        let other = try app("Apps/Other.app", id: "r.other", executable: "Other")
        let local = source()
        let id = try await local.add(url), otherID = try await local.add(other)
        let copy = try app("Elsewhere/Game.app", id: "r.game.copy", executable: "GameCopy")
        try await local.relocate(id, to: copy)
        let value8 = try await local.ownedGames().first { $0.id == id }?.id
        XCTAssertEqual(value8, id)
        do { try await local.relocate(id, to: other); XCTFail("Another game's app cannot be taken") } catch let failure as OperationFailure {
            XCTAssertEqual(failure.stage, "Locate game")
        }
        XCTAssertNotEqual(id, otherID)
    }

    func testResetForgetsTheLibraryButNotTheApps() async throws {
        let url = try app("Apps/Game.app")
        let local = source()
        try await local.add(url)
        try await local.reset()
        let value9 = try await local.ownedGames().isEmpty
        XCTAssertTrue(value9)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
