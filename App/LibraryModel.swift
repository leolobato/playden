import SwiftUI
import Observation
import Domain
import Focus
import Input

enum AppTab: String, CaseIterable { case home = "Home", library = "Library", downloads = "Downloads", settings = "Settings"
    var symbol: String { switch self { case .home: "house"; case .library: "square.grid.2x2"; case .downloads: "arrow.down.to.line"; case .settings: "gearshape" } }
}
enum LibraryFilter: String, CaseIterable { case installed = "Installed", all = "All", favorites = "Favorites", hidden = "Hidden", coop = "Couch co-op", short = "Short sessions" }
enum Panel: Equatable { case context, filters, search, compatibility, information(String) }

@MainActor @Observable
final class LibraryModel {
    var games = PreviewCatalog.games
    var tab: AppTab = .home
    var detailID: GameID?
    var panel: Panel?
    var panelIndex = 0
    var homeRow = 0 { didSet { revealHomeFocus() } }
    var homeColumns: [Int: Int] = [:] { didSet { revealHomeFocus() } }
    var homeScrollOffset = 0.0
    var homeRowOffsets: [Int: Double] = [:]
    var libraryScrollOffset = 0.0
    var libraryCursor = GridCursor() { didSet { revealLibraryFocus() } }
    var railFocused = false
    var filter: LibraryFilter = .all { didSet { libraryCursor = .init(); libraryScrollOffset = 0 } }
    var query = ""
    var sortByPlaytime = false
    var detailAction = 0
    var reducedMotion = false
    var controllerName: String?
    var playStationGlyphs = true
    var downloadPaused = false
    var downloadIndex = 0
    var downloadGames: [Game] {
        ["TUNIC", "Celeste", "Cuphead"].compactMap { title in games.first { $0.title == title } }
    }
    var toast: String?
    var settingsIndex = 0
    var settingsSection = 1
    var settingsRailFocused = false
    var fixedClock = false
    var keyRow = 1
    var keyColumn = 0
    var uppercase = false
    var searchKeys: [[String]] {
        [Array("1234567890").map(String.init), Array(uppercase ? "QWERTYUIOP" : "qwertyuiop").map(String.init), Array(uppercase ? "ASDFGHJKL" : "asdfghjkl").map(String.init), ["⇧"] + Array(uppercase ? "ZXCVBNM" : "zxcvbnm").map(String.init) + ["⌫"], ["Space", "Done"]]
    }
    func activateKey() {
        let key = searchKeys[keyRow][keyColumn]
        switch key {
        case "⇧": uppercase.toggle()
        case "⌫": updateQuery(String(query.dropLast()))
        case "Space": updateQuery(query + " ")
        case "Done": panel = nil
        default: updateQuery(query + key)
        }
    }

    var filteredGames: [Game] {
        let result = games.filter { game in
            guard game.isHidden == (filter == .hidden) else { return false }
            let matches = switch filter {
            case .installed: game.status == .installed || game.status == .driveDisconnected
            case .favorites: game.isFavorite
            case .coop: game.genres.contains("Couch co-op")
            case .short: game.hoursPlayed > 0 && game.hoursPlayed < 8
            case .all, .hidden: true
            }
            return matches && (query.isEmpty || game.title.localizedCaseInsensitiveContains(query))
        }
        return result.sorted { sortByPlaytime && $0.hoursPlayed != $1.hoursPlayed ? $0.hoursPlayed > $1.hoursPlayed : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var rows: [(name: String, games: [Game])] {
        let visible = games.filter { !$0.isHidden }
        return [
            ("Continue playing", ["Hades", "Cuphead", "Hollow Knight", "Dead Cells", "Stardew Valley", "Slay the Spire", "Celeste", "Outer Wilds"].compactMap { title in visible.first { $0.title == title } }),
            ("Downloading now", visible.filter { [.queued, .downloading].contains($0.status) }.sorted { $0.status == .downloading && $1.status != .downloading }),
            ("Recently installed", visible.filter { $0.status == .installed && $0.hoursPlayed <= 9 }),
            ("Favorites", visible.filter(\.isFavorite)),
            ("Couch co-op", visible.filter { $0.genres.contains("Couch co-op") }),
        ].filter { !$0.1.isEmpty }
    }
    var focusedGame: Game? {
        if let detailID { return games.first { $0.id == detailID } }
        if tab == .library { return filteredGames[safe: libraryCursor.index] }
        if tab == .downloads { return downloadGames[safe: downloadIndex] }
        return rows[safe: homeRow]?.games[safe: homeColumns[homeRow, default: 0]]
    }
    var detailActions: [String] {
        guard let game = focusedGame else { return [] }
        let primary = switch game.status { case .installed: "Play"; case .downloading: downloadPaused ? "Resume download" : "Pause download"; case .queued: "View download"; case .driveDisconnected: "Drive disconnected"; case .notInstalled: "Install" }
        return [primary, game.isFavorite ? "Favorited" : "Favorite", "Add to collection", "Hide", "Set compatibility"] + (game.status == .installed ? ["Verify files", "Uninstall"] : []) + ["View logs"]
    }
    var contextActions: [String] { ["Open game", focusedGame?.isFavorite == true ? "Unfavorite" : "Favorite", "Set compatibility", focusedGame?.isHidden == true ? "Unhide" : "Hide", "View logs"] }
    var panelActions: [String] {
        switch panel {
        case .context: contextActions
        case .filters: ["Name", "Playtime", "All games", "Installed", "Favorites", "Reset"]
        case .compatibility: Compatibility.allCases.map(\.rawValue)
        case .information: ["Got it"]
        default: []
        }
    }
    var libraryViewportHeight: Double { query.isEmpty ? 840 : 750 }
    var libraryVisibleIndices: Range<Int> {
        let firstRow = max(0, Int(libraryScrollOffset / 339) - 2)
        let lastRow = Int((libraryScrollOffset + libraryViewportHeight) / 339) + 3
        let count = filteredGames.count
        return min(count, firstRow * 6)..<min(count, lastRow * 6)
    }
    func revealLibraryFocus() {
        let count = filteredGames.count
        let top = 24.0 + Double(libraryCursor.index / 6) * 339
        let content = 48.0 + Double((count + 5) / 6) * 339
        libraryScrollOffset = FocusViewport.reveal(offset: libraryScrollOffset, itemMin: top,
            itemMax: top + 315, viewport: libraryViewportHeight, content: content)
    }
    func revealHomeFocus() {
        let top = 24.0 + Double(homeRow) * 442
        homeScrollOffset = FocusViewport.reveal(offset: homeScrollOffset, itemMin: top,
            itemMax: top + 420, viewport: 840, content: 48 + Double(rows.count) * 442)
        let column = homeColumns[homeRow, default: 0]
        let left = 24.0 + Double(column) * 233
        homeRowOffsets[homeRow] = FocusViewport.reveal(offset: homeRowOffsets[homeRow, default: 0], itemMin: left,
            itemMax: left + 213, viewport: 1848, content: 48 + Double(rows[safe: homeRow]?.games.count ?? 0) * 233)
    }
    func browseAvailableGames() {
        selectTab(.library)
        filter = !games.isEmpty && games.allSatisfy(\.isHidden) ? .hidden : .all
        updateQuery("")
    }
    func selectTab(_ value: AppTab) { tab = value; detailID = nil; panel = nil; railFocused = false }
    func show(_ value: Panel) { panel = value; panelIndex = 0 }
    func updateQuery(_ value: String) { query = value; libraryCursor = .init() }
    func openGame(_ game: Game) { detailID = game.id; detailAction = 0; panel = nil }
    func toggleFavorite() {
        guard let id = focusedGame?.id, let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].isFavorite.toggle(); reconcileFocus()
    }
    func reconcileFocus() {
        libraryCursor.clamp(count: filteredGames.count)
        homeRow = min(homeRow, max(0, rows.count - 1))
        for (i, row) in rows.enumerated() { homeColumns[i] = min(homeColumns[i, default: 0], max(0, row.games.count - 1)) }
    }
    func perform(_ action: InputAction) {
        if panel == .search {
            switch action {
            case .back: panel = nil
            case .confirm: activateKey()
            case .favorite: updateQuery(String(query.dropLast()))
            case .context: updateQuery(query + " ")
            case .move(let direction):
                if direction == .up || direction == .down {
                    keyRow = min(max(0, keyRow + (direction == .up ? -1 : 1)), searchKeys.count - 1)
                    keyColumn = min(keyColumn, searchKeys[keyRow].count - 1)
                } else { keyColumn = min(max(0, keyColumn + (direction == .left ? -1 : 1)), searchKeys[keyRow].count - 1) }
            default: break
            }
            return
        }
        if panel != nil {
            switch action {
            case .back: panel = nil
            case .move(let direction): panelIndex = min(max(0, panelIndex + (direction == .up || direction == .left ? -1 : 1)), max(0, panelActions.count - 1))
            case .confirm: activatePanel()
            default: break
            }
            return
        }
        switch action {
        case .move(let direction): move(direction)
        case .confirm:
            if detailID != nil { activateDetail() }
            else if tab == .settings { activateSetting() }
            else if tab == .downloads {
                if focusedGame?.status == .downloading { downloadPaused.toggle() }
                else if let game = focusedGame { openGame(game) }
            }
            else if tab == .library && railFocused { railFocused = false }
            else if let game = focusedGame { openGame(game) }
            else if tab == .home || tab == .library { browseAvailableGames() }
        case .back:
            if detailID != nil { detailID = nil }
            else if !query.isEmpty { updateQuery("") }
            else { selectTab(.home) }
        case .favorite: if !(tab == .library && railFocused) { toggleFavorite() }
        case .context: if focusedGame != nil && !(tab == .library && railFocused) { show(.context) }
        case .options: if tab == .library && detailID == nil { show(.filters) }
        case .search: selectTab(.library); show(.search)
        case .home: selectTab(.home); homeRow = 0; homeColumns[0] = 0
        case .previousTab, .nextTab:
            let tabs = AppTab.allCases, index = tabs.firstIndex(of: tab) ?? 0
            selectTab(tabs[(index + (action.isNextTab ? 1 : tabs.count - 1)) % tabs.count])
        case .previousPage: for _ in 0..<2 { move(.up) }
        case .nextPage: for _ in 0..<2 { move(.down) }
        }
    }
    private func move(_ direction: Direction) {
        if detailID != nil {
            detailAction = min(max(0, detailAction + (direction == .left ? -1 : direction == .right ? 1 : 0)), detailActions.count - 1)
        } else if tab == .home {
            if direction == .up || direction == .down { homeRow = min(max(0, homeRow + (direction == .up ? -1 : 1)), max(0, rows.count - 1)) }
            else { homeColumns[homeRow] = min(max(0, homeColumns[homeRow, default: 0] + (direction == .left ? -1 : 1)), max(0, (rows[safe: homeRow]?.games.count ?? 0) - 1)) }
        } else if tab == .library {
            if railFocused {
                if direction == .right { railFocused = false }
                else if direction == .up || direction == .down {
                    let values = LibraryFilter.allCases, i = values.firstIndex(of: filter) ?? 1
                    filter = values[min(max(0, i + (direction == .up ? -1 : 1)), values.count - 1)]
                    libraryCursor = .init()
                }
            } else if !libraryCursor.move(direction, count: filteredGames.count, columns: 6), direction == .left { railFocused = true }
        } else if tab == .downloads {
            if direction == .up || direction == .down {
                downloadIndex = min(max(0, downloadIndex + (direction == .up ? -1 : 1)), max(0, downloadGames.count - 1))
            }
        } else if tab == .settings {
            if direction == .left { settingsRailFocused = true }
            else if direction == .right { settingsRailFocused = false }
            else if settingsRailFocused { settingsSection = min(max(0, settingsSection + (direction == .up ? -1 : 1)), 4); settingsIndex = 0 }
            else { settingsIndex = min(max(0, settingsIndex + (direction == .up ? -1 : 1)), settingsSection == 1 ? 3 : settingsSection == 2 ? 1 : 0) }
        }
    }
    func activateDetail() {
        guard let label = detailActions[safe: detailAction] else { return }
        switch label {
        case "Favorite", "Favorited": toggleFavorite()
        case "Hide": hideFocused()
        case "Set compatibility": show(.compatibility)
        case "Pause download", "Resume download": downloadPaused.toggle()
        case "View download": selectTab(.downloads)
        default: show(.information("This is the design preview. \(label) will connect to the real game service in a later milestone. No game files are changed."))
        }
    }
    func activatePanel() {
        guard let label = panelActions[safe: panelIndex] else { return }
        switch panel {
        case .context:
            if label == "Open game", let game = focusedGame { openGame(game) }
            else if label == "Favorite" || label == "Unfavorite" { toggleFavorite(); panel = nil }
            else if label == "Set compatibility" { show(.compatibility) }
            else if label == "Hide" || label == "Unhide" { hideFocused(); panel = nil }
            else { show(.information("Logs will appear here when real installation and play sessions are connected.")) }
        case .filters:
            if label == "Name" { sortByPlaytime = false }
            if label == "Playtime" { sortByPlaytime = true }
            if label == "All games" { filter = .all }
            if label == "Installed" { filter = .installed }
            if label == "Favorites" { filter = .favorites }
            if label == "Reset" { sortByPlaytime = false; filter = .all; query = "" }
            libraryCursor = .init()
        case .compatibility:
            if let id = focusedGame?.id, let i = games.firstIndex(where: { $0.id == id }), let rating = Compatibility(rawValue: label) { games[i].compatibility = rating }
            panel = nil
        default: panel = nil
        }
    }
    private func hideFocused() {
        guard let id = focusedGame?.id, let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].isHidden.toggle(); detailID = nil; reconcileFocus()
    }
    func activateSetting() {
        if settingsRailFocused { settingsRailFocused = false; return }
        if settingsSection == 2 && settingsIndex == 1 { reducedMotion.toggle() }
        else { show(.information("The native interface is running with designer preview data. Steam, game installation, and CrossOver sessions are not connected yet.")) }
    }
}
private extension InputAction { var isNextTab: Bool { if case .nextTab = self { true } else { false } } }
extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
