import Foundation
import Domain
import Input

extension LibraryModel {
    var libraryFilters: [LibraryFilter] { [.installed, .all, .favorites, .hidden] + collections.map { .collection($0.id) } }
    func filterTitle(_ value: LibraryFilter) -> String {
        switch value {
        case .installed: "Installed"
        case .all: "All"
        case .favorites: "Favorites"
        case .hidden: "Hidden"
        case .collection(let id): collections.first { $0.id == id }?.name ?? "Collection"
        }
    }
    func count(for value: LibraryFilter) -> Int {
        games.filter { game in
            if value == .hidden { return game.isHidden }
            guard !game.isHidden else { return false }
            return switch value {
            case .all: true
            case .installed: [.installed, .driveDisconnected].contains(game.status)
            case .favorites: game.isFavorite
            case .hidden: false
            case .collection(let id): collections.first { $0.id == id }?.gameIDs.contains(game.id) == true
            }
        }.count
    }
    var isEditingText: Bool {
        if panel == .search { return true }
        if case .textEditor = panel { return true }
        return false
    }
    var keyboardTitle: String {
        switch panel {
        case .search: "Search your library"
        case .textEditor(.newCollection): "New collection"
        case .textEditor(.renameCollection): "Rename collection"
        case .textEditor(.compatibilityNote): "Compatibility note"
        default: "Enter text"
        }
    }
    func beginText(_ purpose: TextPurpose) {
        let initial: String
        switch purpose {
        case .newCollection: initial = ""
        case .renameCollection(let id): initial = collections.first { $0.id == id }?.name ?? ""
        case .compatibilityNote(let id): initial = compatibilityNotes[id] ?? ""
        }
        textEditor = TextEditorState(initial); keyboardError = nil
        show(.textEditor(purpose))
    }
    func insertText(_ value: String) {
        let printable = String(value.filter { !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } })
        let limit = panel == .search ? 120 : 500
        textEditor.insert(String(printable.prefix(max(0, limit - textEditor.text.count))))
        keyboardError = nil
        if panel == .search { updateQuery(textEditor.text) }
    }
    func eraseText() {
        textEditor.backspace(); keyboardError = nil
        if panel == .search { updateQuery(textEditor.text) }
    }
    func toggleSymbols() {
        symbols.toggle(); keyRow = min(keyRow, searchKeys.count - 1)
        keyColumn = min(keyColumn, searchKeys[keyRow].count - 1)
    }
    func cancelText() {
        if case .textEditor(.compatibilityNote) = panel { show(.compatibility) }
        else { panel = nil }
    }
    func finishText() {
        guard case .textEditor(let purpose) = panel else { panel = nil; return }
        let value = textEditor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .compatibilityNote(let id) = purpose {
            compatibilityNotes[id] = value
            show(.compatibility); return
        }
        guard !value.isEmpty, value.count <= 40 else { keyboardError = "Use a name between 1 and 40 characters."; return }
        let existingID: UUID? = { if case .renameCollection(let id) = purpose { return id }; return nil }()
        guard !collections.contains(where: { $0.id != existingID && $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame }) else {
            keyboardError = "A collection with this name already exists."; return
        }
        switch purpose {
        case .newCollection(let gameID):
            let collection = GameCollection(name: value, gameIDs: Set(gameID.map { [$0] } ?? []))
            collections.append(collection)
            if let gameID { show(.collections(gameID)) }
            else { filter = .collection(collection.id); railFocused = true; panel = nil }
        case .renameCollection(let id):
            if let index = collections.firstIndex(where: { $0.id == id }) { collections[index].name = value }
            show(.collectionOptions(id))
        case .compatibilityNote: break
        }
        reconcileFocus()
    }
    func confirmationAction(_ intent: Confirmation) -> String {
        switch intent { case .deleteCollection: "Delete collection"; case .uninstall: "Uninstall"; case .install: "Add to downloads"; case .cancelDownload: "Cancel download" }
    }
    func confirmationTitle(_ intent: Confirmation) -> String {
        switch intent {
        case .deleteCollection(let id): "Delete ‘\(collections.first { $0.id == id }?.name ?? "collection")’?"
        case .uninstall(let id): "Uninstall \(gameName(id))?"
        case .install(let id): "Install \(gameName(id))?"
        case .cancelDownload(let id): "Cancel \(gameName(id)) download?"
        }
    }
    func confirmationMessage(_ intent: Confirmation) -> String {
        switch intent {
        case .deleteCollection: "Only the collection is removed. Your games, favorites and play history are kept."
        case .uninstall: "Remove this preview installation. Game files and saves on your Mac are untouched while the runtime is disconnected."
        case .install(let id): "\(games.first { $0.id == id }?.size ?? "Unknown size") required. This adds a preview queue entry; downloading will be available when Steam is connected."
        case .cancelDownload: "Remove this entry from the preview queue. No game files on your Mac are changed."
        }
    }
    func confirm(_ intent: Confirmation) {
        switch intent {
        case .deleteCollection(let id):
            collections.removeAll { $0.id == id }
            if filter == .collection(id) { filter = .all }
            libraryRailIndex = min(libraryRailIndex, libraryFilters.count - 1)
        case .uninstall(let id):
            if let i = games.firstIndex(where: { $0.id == id }) { games[i].status = .notInstalled }
            detailAction = 0
        case .install(let id):
            if let i = games.firstIndex(where: { $0.id == id }) { games[i].status = .queued }
            if !queueOrder.contains(id) { queueOrder.append(id) }
            detailAction = 0
        case .cancelDownload(let id):
            queueOrder.removeAll { $0 == id }
            if let i = games.firstIndex(where: { $0.id == id }) { games[i].status = .notInstalled }
        }
        panel = nil; reconcileFocus()
    }
    func gameName(_ id: GameID) -> String { games.first { $0.id == id }?.title ?? "Game" }
    var panelTitle: String {
        switch panel {
        case .filters: "Sort & filter"
        case .compatibility: "Compatibility"
        case .collections: "Add to collection"
        case .collectionOptions(let id): collections.first { $0.id == id }?.name ?? "Collection"
        default: focusedGame?.title ?? "Game"
        }
    }
    func panelItemSelected(at index: Int) -> Bool {
        switch panel {
        case .collections(let id): collections[safe: index]?.gameIDs.contains(id) == true
        case .compatibility: index < Compatibility.allCases.count && focusedGame?.compatibility == Compatibility.allCases[index]
        case .filters: (index == 0 && !sortByPlaytime) || (index == 1 && sortByPlaytime)
        default: false
        }
    }
}
