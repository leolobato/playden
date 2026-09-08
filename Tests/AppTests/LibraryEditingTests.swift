import XCTest
import Domain
import Input
@testable import Playden

final class LibraryEditingTests: XCTestCase {
    @MainActor func testKeyboardMovesByKeyCentersAndKeepsItsColumnThroughWideKeys() {
        let model = LibraryModel()
        model.beginText(.newCollection(nil))
        model.keyRow = 4; model.keyColumn = 0
        model.perform(.move(.up))
        XCTAssertEqual(model.searchKeys[model.keyRow][model.keyColumn], "c")
        model.keyPreferredX = nil; model.keyRow = 1; model.keyColumn = 9
        model.perform(.move(.down))
        XCTAssertEqual(model.searchKeys[model.keyRow][model.keyColumn], "l")
        model.perform(.move(.down)); model.perform(.move(.down))
        XCTAssertEqual(model.searchKeys[model.keyRow][model.keyColumn], "Done")
        model.perform(.move(.up))
        XCTAssertEqual(model.searchKeys[model.keyRow][model.keyColumn], "⌫")
        model.perform(.move(.down)); model.perform(.move(.left)); model.perform(.move(.right))
        model.perform(.move(.up))
        XCTAssertEqual(model.searchKeys[model.keyRow][model.keyColumn], "n")
        model.perform(.options)
        for _ in 0..<10 { model.perform(.move(.down)) }
        XCTAssertTrue(model.searchKeys[model.keyRow].indices.contains(model.keyColumn))
        model.perform(.options)
        for _ in 0..<10 { model.perform(.move(.up)) }
        XCTAssertEqual(model.keyRow, 0)
        XCTAssertTrue(model.searchKeys[model.keyRow].indices.contains(model.keyColumn))
        XCTAssertTrue(model.isEditingText)
    }
    func testCharacterCursorPreservesEmojiAndCombiningAccents() {
        var editor = TextEditorState("A👨‍👩‍👧‍👦é")
        editor.moveCursor(by: -1)
        editor.backspace()
        XCTAssertEqual(editor.text, "Aé")
        editor.insert("🎮")
        XCTAssertEqual(editor.beforeCursor, "A🎮")
        XCTAssertEqual(editor.afterCursor, "é")
        editor.moveCursor(by: -100); editor.backspace()
        XCTAssertEqual(editor.text, "A🎮é")
        editor = TextEditorState("e")
        editor.insert("\u{301}")
        XCTAssertEqual(editor.cursor, 1)
        editor.backspace()
        XCTAssertTrue(editor.text.isEmpty)
    }

    @MainActor func testCollectionLifecycleKeepsGameData() throws {
        let model = LibraryModel()
        let game = try XCTUnwrap(model.focusedGame)
        let originalGames = model.games
        model.beginText(.newCollection(game.id)); model.insertText("Weekend 🎮"); model.finishText()
        let collection = try XCTUnwrap(model.collections.last)
        XCTAssertEqual(collection.name, "Weekend 🎮")
        XCTAssertTrue(collection.gameIDs.contains(game.id))
        XCTAssertEqual(model.panel, .collections(game.id))
        model.panelIndex = model.collections.count - 1
        model.perform(.confirm)
        XCTAssertFalse(model.collections.last!.gameIDs.contains(game.id))
        model.perform(.confirm)
        XCTAssertTrue(model.collections.last!.gameIDs.contains(game.id))
        model.show(.collectionOptions(collection.id)); model.panelIndex = 1; model.perform(.confirm)
        XCTAssertTrue(model.rows.contains { $0.name == "Weekend 🎮" && $0.games.contains { $0.id == game.id } })
        model.beginText(.renameCollection(collection.id)); model.textEditor = TextEditorState("Rainy days"); model.finishText()
        XCTAssertEqual(model.collections.last?.name, "Rainy days")
        model.filter = .collection(collection.id)
        model.show(.confirmation(.deleteCollection(collection.id))); model.perform(.confirm)
        XCTAssertTrue(model.collections.contains { $0.id == collection.id })
        model.show(.confirmation(.deleteCollection(collection.id))); model.perform(.move(.right)); model.perform(.confirm)
        XCTAssertFalse(model.collections.contains { $0.id == collection.id })
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.games, originalGames)
    }

    @MainActor func testCollectionValidationAndTextCancel() {
        let model = LibraryModel()
        let original = model.collections
        model.beginText(.newCollection(nil)); model.finishText()
        XCTAssertNotNil(model.keyboardError)
        model.insertText(original[0].name.uppercased()); model.finishText()
        XCTAssertNotNil(model.keyboardError)
        XCTAssertEqual(model.collections, original)
        model.perform(.back)
        XCTAssertNil(model.panel)
        model.beginText(.renameCollection(original[0].id))
        model.insertText(" unsaved"); model.perform(.back)
        XCTAssertEqual(model.collections, original)
    }

    @MainActor func testTextCursorIsTrappedAndCompatibilityNoteCanBeCancelled() throws {
        let model = LibraryModel()
        let id = try XCTUnwrap(model.focusedGame?.id)
        model.beginText(.compatibilityNote(id)); model.insertText("Works 🎮")
        model.perform(.previousTab); model.insertText("well ")
        XCTAssertEqual(model.textEditor.text, "Works well 🎮")
        XCTAssertEqual(model.tab, .home)
        model.perform(.options)
        XCTAssertTrue(model.symbols)
        model.finishText()
        XCTAssertEqual(model.compatibilityNotes[id], "Works well 🎮")
        XCTAssertEqual(model.panel, .compatibility)
        model.beginText(.compatibilityNote(id)); model.insertText(" discarded"); model.perform(.back)
        XCTAssertEqual(model.compatibilityNotes[id], "Works well 🎮")
        XCTAssertEqual(model.panel, .compatibility)
    }

    @MainActor func testPreviewQueueReorderingCancellationAndEmptyRecovery() throws {
        let model = LibraryModel()
        let game = try XCTUnwrap(model.games.first { $0.status == .notInstalled })
        model.show(.confirmation(.install(game.id))); model.perform(.confirm)
        XCTAssertFalse(model.downloadGames.contains { $0.id == game.id })
        model.show(.confirmation(.install(game.id))); model.perform(.move(.right)); model.perform(.confirm)
        XCTAssertEqual(model.downloadGames.filter { $0.status == .queued }.last?.id, game.id)
        model.openGame(model.games.first { $0.id == game.id }!)
        model.perform(.confirm)
        XCTAssertEqual(model.tab, .downloads)
        XCTAssertEqual(model.focusedGame?.id, game.id)
        model.perform(.context); model.perform(.confirm) // Move up
        XCTAssertEqual(model.downloadGames.filter { $0.status == .queued }.first?.id, game.id)
        XCTAssertEqual(model.focusedGame?.id, game.id)
        model.activateDownloadAction("Cancel download…", id: game.id)
        model.perform(.confirm)
        XCTAssertTrue(model.downloadGames.contains { $0.id == game.id })
        model.activateDownloadAction("Cancel download…", id: game.id)
        model.perform(.move(.right)); model.perform(.confirm)
        XCTAssertFalse(model.downloadGames.contains { $0.id == game.id })
        XCTAssertNotNil(model.focusedGame)
        for game in model.downloadGames { model.confirm(.cancelDownload(game.id)) }
        model.completedDownloads.removeAll()
        XCTAssertTrue(model.downloadGames.isEmpty)
        model.perform(.confirm)
        XCTAssertEqual(model.tab, .library)
        XCTAssertFalse(model.filteredGames.isEmpty)
    }

    @MainActor func testLongQueueScrollFollowsFocusInBothDirections() {
        let model = LibraryModel()
        for index in model.games.indices { model.games[index].status = .queued }
        model.selectTab(.downloads)
        for _ in model.games { model.perform(.move(.down)) }
        XCTAssertGreaterThan(model.downloadScrollOffset, 0)
        for _ in model.games { model.perform(.move(.up)) }
        XCTAssertEqual(model.downloadIndex, 0)
        XCTAssertEqual(model.downloadScrollOffset, 0)
    }
}
