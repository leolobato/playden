import Foundation
import Domain
import Input
import Focus

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
        case .textEditor(.accountName): "Steam account name"
        case .textEditor(.password): "Steam password"
        case .textEditor(.guardCode): "Steam Guard code"
        case .textEditor(.renameCollection): "Rename collection"
        case .textEditor(.compatibilityNote): "Compatibility note"
        case .textEditor(.runtimeText(_, let setting)): GameSettingsCatalog.definition(setting).title
        default: "Enter text"
        }
    }
    func beginText(_ purpose: TextPurpose) {
        let initial: String
        switch purpose {
        case .newCollection: initial = ""
        case .accountName: initial = accountNameDraft
        case .password, .guardCode: initial = ""
        case .renameCollection(let id): initial = collections.first { $0.id == id }?.name ?? ""
        case .compatibilityNote(let id): initial = compatibilityNotes[id] ?? ""
        case .runtimeText(let id, let setting):
            if case .list(let values)? = resolvedValues(id).resolved[setting] {
                initial = setting == .launchArguments
                    ? values.map { $0.contains(where: \.isWhitespace) ? "\"\($0)\"" : $0 }.joined(separator: " ")
                    : values.joined(separator: " ")
            } else { initial = "" }
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
        keyPreferredX = nil
        symbols.toggle(); keyRow = min(keyRow, searchKeys.count - 1)
        keyColumn = min(keyColumn, searchKeys[keyRow].count - 1)
    }
    func keyboardKeyWidth(_ key: String) -> Double { key == "Space" ? 520 : key == "Done" ? 180 : 96 }
    private func keyboardCenters(_ row: Int) -> [Double] {
        let widths = searchKeys[row].map(keyboardKeyWidth)
        var edge = -(widths.reduce(0, +) + Double(max(0, widths.count - 1)) * 8) / 2
        return widths.map { width in
            defer { edge += width + 8 }
            return edge + width / 2
        }
    }
    func moveKeyboardFocus(_ direction: Direction) {
        if direction == .up || direction == .down {
            let next = min(max(0, keyRow + (direction == .up ? -1 : 1)), searchKeys.count - 1)
            guard next != keyRow else { return }
            let x = keyPreferredX ?? keyboardCenters(keyRow)[keyColumn]
            keyPreferredX = x
            let centers = keyboardCenters(next)
            keyColumn = centers.indices.min { abs(centers[$0] - x) < abs(centers[$1] - x) } ?? 0
            keyRow = next
        } else {
            keyColumn = min(max(0, keyColumn + (direction == .left ? -1 : 1)), searchKeys[keyRow].count - 1)
            keyPreferredX = nil
        }
    }
    var maskedText: Bool { panel == .textEditor(.password) || panel == .textEditor(.guardCode) }
    func cancelText() {
        if maskedText { textEditor = TextEditorState() }
        if case .textEditor(.compatibilityNote) = panel { show(.compatibility) }
        else if case .textEditor(.runtimeText(let id, _)) = panel { gameSettingsError = nil; returnToGameSettings(id) }
        else { panel = nil }
    }
    func finishText() {
        guard case .textEditor(let purpose) = panel else { panel = nil; return }
        if purpose == .accountName || purpose == .password || purpose == .guardCode {
            finishAuthenticationText(purpose); return
        }
        let value = textEditor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .compatibilityNote(let id) = purpose {
            compatibilityNotes[id] = value
            show(.compatibility); return
        }
        if case .runtimeText(let id, let setting) = purpose {
            switch RuntimeTextValidation.parse(value, for: setting) {
            case .success(let values):
                if setOverride(id, setting, values.isEmpty ? nil : .list(values)) {
                    gameSettingsError = nil
                    returnToGameSettings(id)
                } else {
                    keyboardError = "Could not save game settings. Try again."
                }
            case .failure(let error): keyboardError = error.message
            }
            return
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
        case .compatibilityNote, .accountName, .password, .guardCode, .runtimeText: break
        }
        reconcileFocus()
    }
    func confirmationAction(_ intent: Confirmation) -> String {
        switch intent { case .deleteCollection: "Delete collection"; case .uninstall: "Uninstall"; case .install: "Add to downloads"; case .cancelDownload(let id): liveJob(for: id)?.kind == .repair ? "Stop verifying" : "Cancel download"; case .switchGame: "Quit and play" }
    }
    func confirmationTitle(_ intent: Confirmation) -> String {
        switch intent {
        case .deleteCollection(let id): "Delete ‘\(collections.first { $0.id == id }?.name ?? "collection")’?"
        case .uninstall(let id): "Uninstall \(gameName(id))?"
        case .install(let id): "Install \(gameName(id))?"
        case .cancelDownload(let id): liveJob(for: id)?.kind == .repair ? "Stop verifying \(gameName(id))?" : "Cancel \(gameName(id)) download?"
        case .switchGame(let id): "Play \(gameName(id))?"
        }
    }
    func confirmationMessage(_ intent: Confirmation) -> String {
        switch intent {
        case .deleteCollection: "Only the collection is removed. Your games, favorites and play history are kept."
        case .uninstall: "Remove this preview installation. Game files and saves on your Mac are untouched while the runtime is disconnected."
        case .install(let id): "\(games.first { $0.id == id }?.size ?? "Unknown size") required. This adds a preview queue entry; downloading will be available when Steam is connected."
        case .cancelDownload(let id): liveJob(for: id)?.kind == .repair ? "Your game files and saves are kept. Verification must finish before you can play again." : isPreview ? "Remove this entry from the preview queue. No game files on your Mac are changed." : "Stop this installation and remove its downloaded files. You can install the game again from your library."
        case .switchGame: "\(session.game?.title ?? "Another game") is still running. Quit it before starting this game. Unsaved progress may be lost."
        }
    }
    func confirm(_ intent: Confirmation) {
        switch intent {
        case .switchGame(let id): switchToGame(id); return
        case .deleteCollection(let id):
            collections.removeAll { $0.id == id }
            if filter == .collection(id) { filter = .all }
            libraryRailIndex = min(libraryRailIndex, libraryFilters.count - 1)
        case .uninstall(let id):
            if !isPreview { beginUninstall(id); return }
            if let i = games.firstIndex(where: { $0.id == id }) { games[i].status = .notInstalled }
            detailAction = 0
        case .install(let id):
            if let i = games.firstIndex(where: { $0.id == id }) { games[i].status = .queued }
            if !queueOrder.contains(id) { queueOrder.append(id) }
            detailAction = 0
        case .cancelDownload(let id):
            if !isPreview { cancelLiveDownload(id); return }
            queueOrder.removeAll { $0 == id }
            if let i = games.firstIndex(where: { $0.id == id }) { games[i].status = .notInstalled }
        }
        panel = nil; reconcileFocus()
    }
    func gameName(_ id: GameID) -> String { games.first { $0.id == id }?.title ?? liveJob(for: id)?.plan?.game.title ?? liveJob(for: id)?.originalInstallation?.game.title ?? "Game" }
    var panelTitle: String {
        switch panel {
        case .downloadActions(let id): gameName(id)
        case .volumePicker(let id): id == nil ? "Default install volume" : "Install on volume"
        case .filters: "Sort & filter"
        case .persistenceFailure: "Changes weren’t saved"
        case .signOut: "Sign out of Steam?"
        case .compatibility: "Compatibility"
        case .collections: "Add to collection"
        case .collectionOptions(let id): collections.first { $0.id == id }?.name ?? "Collection"
        default: focusedGame?.title ?? "Game"
        }
    }
    func panelItemSelected(at index: Int) -> Bool {
        switch panel {
        case .volumePicker(let id): enabledInstallVolumes[safe: index]?.volumeID == (id == nil ? gamesVolume : installDestination)?.volumeID
        case .collections(let id): collections[safe: index]?.gameIDs.contains(id) == true
        case .compatibility: index < Compatibility.allCases.count && focusedGame?.compatibility == Compatibility.allCases[index]
        default: false
        }
    }
}
