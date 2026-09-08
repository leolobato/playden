import SwiftUI
import Observation
import Domain
import Focus
import Input
import Catalog
import Runner
import Installs
import Sessions
import Sources

enum AppTab: String, CaseIterable { case home = "Home", library = "Library", downloads = "Downloads", settings = "Settings"
    var symbol: String { switch self { case .home: "house"; case .library: "square.grid.2x2"; case .downloads: "arrow.down.to.line"; case .settings: "gearshape" } }
}
typealias LibraryFilter = LibraryScope
enum TextPurpose: Equatable { case newCollection(GameID?), renameCollection(UUID), compatibilityNote(GameID), accountName, password, guardCode }
enum Confirmation: Equatable { case deleteCollection(UUID), uninstall(GameID), install(GameID), cancelDownload(GameID), switchGame(GameID) }
enum Panel: Equatable {
    case context, filters, search, compatibility, information(String), persistenceFailure, signOut, controllerTest, resetAppData
    case downloadActions(GameID)
    case installOffer(GameID)
    case cloudSaves(GameID)
    case uninstall(GameID)
    case textEditor(TextPurpose), collections(GameID), collectionOptions(UUID), confirmation(Confirmation), logs(GameID)
}

struct HomeRow {
    let name: String
    let games: [Game]
    let showsLibraryCard: Bool
    var itemCount: Int { games.count + (showsLibraryCard ? 1 : 0) }
}

@MainActor @Observable
final class LibraryModel {
    @ObservationIgnored let catalog: CatalogStore?
    @ObservationIgnored let diagnosticArchive: DiagnosticArchive?
    @ObservationIgnored var logObserver: Task<Void, Never>?
    var logDocument: DiagnosticLog?
    var logArchiveError: String?
    var logScrollRequest = LogScrollRequest()
    var logScrollFraction = 0.0
    var logCanScroll = false
    var logActionIndex = 0
    @ObservationIgnored let source: (any GameSource)?
    @ObservationIgnored let syncCoordinator: LibrarySyncCoordinator?
    @ObservationIgnored let runtime: (any BottleManaging)?
    @ObservationIgnored let volumeStore: (any VolumeManaging)?
    @ObservationIgnored let installQueue: (any InstallQueuing)?
    @ObservationIgnored let sessions: (any SessionManaging)?
    @ObservationIgnored let cloudService: (any CloudSyncManaging)?
    @ObservationIgnored var cloudObserver: Task<Void, Never>?
    @ObservationIgnored var cloudCommands: [GameID: Task<Void, Never>] = [:]
    var cloudStatuses: [GameID: CloudSyncStatus] = [:]
    var cloudAvailability: [GameID: Bool] = [:]
    @ObservationIgnored var cloudInstallationIDs: [GameID: UUID] = [:]
    var cloudReview: CloudSyncOperation?
    @ObservationIgnored var uninstallTask: Task<Void, Never>?
    var uninstallBusy = false
    var uninstallReview: UninstallReview?
    var uninstallInstallation: InstallationRecord?
    var uninstallPhase: UninstallPhase = .confirm
    var uninstallError: String?
    @ObservationIgnored var sessionObserver: Task<Void, Never>?
    @ObservationIgnored var sessionStartup: Task<Void, Never>?
    @ObservationIgnored var sessionCommand: Task<Void, Never>?
    @ObservationIgnored var onGameWindow: ((GameWindow) -> Void)?
    @ObservationIgnored var onGameStarted: (() -> Void)?
    @ObservationIgnored var onGameEnded: (() -> Void)?
    @ObservationIgnored var onExitOverlayChanged: ((Bool) -> Void)?
    var session = SessionSnapshot()
    var sessionReady = false
    var sessionIssue: OperationFailure? { didSet { if oldValue != sessionIssue { sessionIssueFocused = false; sessionIssueIndex = 0 } } }
    var sessionIssueFocused = false
    var sessionIssueIndex = 0
    var sessionOrigin: AppTab = .library
    var exitOverlay = false
    var exitIndex = 0
    var sessionBusy = false
    @ObservationIgnored var installObserver: Task<Void, Never>?
    @ObservationIgnored var installOfferTask: Task<Void, Never>?
    var installOffer: InstallOffer?
    var installOfferError: String?
    var resolvingInstall = false
    @ObservationIgnored let gamesStorageReader: (any GamesStorageReading)?
    var gamesStorage: GamesStorageSnapshot?
    var gamesStorageError: String?
    var installJobs: [JobRecord] = []
    var downloadDismissals: [UUID: JobHistoryDismissal] = [:]
    var downloadHistoryReview: JobRecord?
    var activeInstallID: UUID?
    var installTransfer: InstallTransferMetrics?
    var installPersistenceError: String?
    @ObservationIgnored var setupTask: Task<Void, Never>?
    @ObservationIgnored var setupGeneration = UUID()
    @ObservationIgnored var onDisplaySelected: ((UInt32) -> Void)?
    @ObservationIgnored var onFullscreenRequested: ((Bool) -> Void)?
    var setupScreen: SetupScreen?
    var setupIndex = 0
    var onboarding = false
    var setupBusy = false
    var volumeSaving = false
    var setupFailure: OperationFailure?
    var templateStage: TemplateStage = .checking
    var runtimeInfo: RuntimeInfo?
    var runtimeChecking = false
    var availableVolumes: [GamesVolume] = []
    var selectedVolumeID: String?
    var gamesVolume: GamesVolumeSelection?
    var displays: [DisplayChoice] = []
    var selectedDisplayID: UInt32?
    var selectedDisplayUUID: String?
    var selectedDisplayName: String?
    var currentDisplayName: String?
    var isFullscreen = false
    var fullscreenTransitioning = false
    var startInFullscreen = true
    var controllerDisconnected = false
    @ObservationIgnored var authTask: Task<Void, Never>?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var periodicSyncTask: Task<Void, Never>?
    @ObservationIgnored var guardContinuation: CheckedContinuation<String, Error>?
    var identity: SourceIdentity?
    var authScreen: AuthenticationScreen?
    var authIndex = 0
    var authAttempt = UUID()
    var authQR: URL?
    var authExpiresAt: Date?
    var authMessage = "Connecting to Steam…"
    var authError: String?
    var accountNameDraft = ""
    var passwordDraft = ""
    var syncError: String?
    var syncing = false
    @ObservationIgnored var restoringState = true
    let isPreview: Bool
    var persistenceError: String?
    var gamesNeedingRepair: Set<GameID> = []
    var games = PreviewCatalog.games { didSet { persistGameEdits(previous: oldValue) } }
    var collections = PreviewCatalog.collections { didSet { persistCollections() } }
    var compatibilityNotes: [GameID: String] = [:] { didSet { persistNotes(previous: oldValue) } }
    var libraryRailIndex = 1
    var textEditor = TextEditorState()
    var keyboardError: String?
    var symbols = false
    var downloadWhilePlaying = false { didSet { persistPreferences(); updateSessionDownloadPolicy() } }
    var tabsFocused = false
    var tab: AppTab = .home
    var detailID: GameID?
    var panel: Panel? {
        didSet {
            if case .installOffer = oldValue, panel != oldValue { installOfferTask?.cancel(); resolvingInstall = false }
            if case .downloadActions(let id) = panel { downloadHistoryReview = liveJob(for: id) }
            else { downloadHistoryReview = nil }
            if case .logs(let id) = panel, panel != oldValue { prepareLogView(id) }
        }
    }
    var panelIndex = 0
    var homeRow = 0 { didSet { revealHomeFocus() } }
    var homeColumns: [Int: Int] = [:] { didSet { revealHomeFocus() } }
    var homeScrollOffset = 0.0
    var homeRowOffsets: [Int: Double] = [:]
    var libraryScrollOffset = 0.0
    var libraryCursor = GridCursor() { didSet { revealLibraryFocus() } }
    var railFocused = false
    var filter: LibraryFilter = .all { didSet { libraryCursor = .init(); libraryScrollOffset = 0; libraryRailIndex = libraryFilters.firstIndex(of: filter) ?? 1; persistPreferences() } }
    var query = ""
    var sort: LibrarySort = .name { didSet { libraryCursor = .init(); persistPreferences() } }
    var refinements = LibraryRefinements() { didSet { libraryCursor = .init(); persistPreferences() } }
    var filterChoiceIndex = 0
    var filterScrollOffset = 0.0
    var expandedGenres = false
    var detailAction = 0
    var reducedMotion = false { didSet { persistPreferences() } }
    var controllerName: String?
    var connectedControllers: [ControllerSnapshot] = []
    var controllerTest = ControllerTestState()
    var playStationGlyphs = true
    var keyboardNavigation = false
    var downloadPaused = false
    var downloadIndex = 0 { didSet { revealDownloadFocus() } }
    var downloadScrollOffset = 0.0
    var queueOrder = PreviewCatalog.games.filter { $0.status == .queued }.map(\.id)
    var completedDownloads = Set(PreviewCatalog.games.filter { $0.title == "Cuphead" }.map(\.id))
    var toast: String?
    var settingsIndex = 0
    var settingsSection = 1
    var settingsRailFocused = false
    var resetBusy = false
    var resetError: String?
    var resetBlocker: String?
    @ObservationIgnored var resetTask: Task<Void, Never>?
    var fixedClock = false
    var keyRow = 1
    var keyColumn = 0
    var uppercase = false
    init(catalog: CatalogStore? = nil, preview: Bool = true, source: (any GameSource)? = nil, runtime: (any BottleManaging)? = nil, volumeStore: (any VolumeManaging)? = nil, installQueue: (any InstallQueuing)? = nil, sessions: (any SessionManaging)? = nil, cloud: (any CloudSyncManaging)? = nil, gamesStorageReader: (any GamesStorageReading)? = nil, diagnosticArchive: DiagnosticArchive? = nil) {
        self.catalog = catalog; self.isPreview = preview; self.source = source
        self.diagnosticArchive = diagnosticArchive
        self.runtime = runtime; self.volumeStore = volumeStore
        self.gamesStorageReader = gamesStorageReader ?? (!preview && catalog != nil ? GamesStorageReader(volumes: volumeStore ?? GamesVolumeStore()) : nil)
        self.syncCoordinator = catalog.map { LibrarySyncCoordinator(catalog: $0) }
        if let installQueue { self.installQueue = installQueue }
        else if !preview, let catalog, let source {
            do { self.installQueue = try InstallQueue(catalog: catalog, sources: [source], storage: InstallStorage(volumes: volumeStore ?? GamesVolumeStore()), bottles: CrossOverGameBottles(runtime: runtime ?? CrossOverRuntime())) }
            catch { self.installQueue = nil; self.installPersistenceError = error.localizedDescription }
        } else { self.installQueue = nil }
        if let cloud { self.cloudService = cloud }
        else if !preview, let catalog, let steam = source as? SteamSource {
            let access = CloudSaveAccess(catalog: catalog, storage: InstallStorage(volumes: volumeStore ?? GamesVolumeStore()),
                bottles: CrossOverGameBottles(runtime: runtime ?? CrossOverRuntime()))
            self.cloudService = CloudSyncService(catalog: catalog, reader: SteamCloudReader(account: steam.account),
                writer: SteamCloudUploader(account: steam.account), roots: { try await access.roots(for: $0) },
                validateUploads: { installed, uploads, deleting in
                    try SteamSaveValidation.validate(installed, uploads: uploads, deleting: deleting,
                        previousSession: catalog.latestRuntimeSession(for: installed.gameID))
                })
        } else { self.cloudService = nil }
        if let sessions { self.sessions = sessions }
        else if !preview, installQueue == nil, let catalog, let source, let queue = self.installQueue {
            do {
                let runner = CrossOverRunner(manager: CrossOverGameBottles(runtime: runtime ?? CrossOverRuntime()),
                    displayHelper: Bundle.main.url(forResource: "BigScreenDisplay", withExtension: "exe"),
                    displayTarget: { @MainActor in GameDisplay.target(preferences: try catalog.preferences()) })
                self.sessions = try SessionService(catalog: catalog, sources: [source], runner: runner, queue: queue,
                    storage: InstallStorage(volumes: volumeStore ?? GamesVolumeStore()), cloud: self.cloudService)
            }
            catch { self.sessions = nil; self.sessionIssue = error as? OperationFailure ?? .init(stage: "Start sessions", reason: error.localizedDescription, output: error.localizedDescription) }
        } else { self.sessions = nil }
        if !preview { games = []; collections = []; queueOrder = []; completedDownloads = [] }
        loadDownloadHistory()
        restoreCatalog()
        refreshCloudAvailability()
        restoringState = false
    }
    var searchKeys: [[String]] {
        func keys(_ string: String) -> [String] { string.map { String($0) } }
        if symbols { return [keys("!@#$%&*()?"), keys("-_=+[]{}<>"), keys(".,:;/\\'\"~"), ["ABC", "⌫"], ["Space", "Done"]] }
        let bottom = ["#+=", "⇧"] + keys(uppercase ? "ZXCVBNM" : "zxcvbnm") + ["⌫"]
        return [keys("1234567890"), keys(uppercase ? "QWERTYUIOP" : "qwertyuiop"), keys(uppercase ? "ASDFGHJKL" : "asdfghjkl"), bottom, ["Space", "Done"]]
    }
    func activateKey() {
        let key = searchKeys[keyRow][keyColumn]
        switch key {
        case "⇧": uppercase.toggle()
        case "#+=", "ABC": toggleSymbols()
        case "⌫": eraseText()
        case "Space": insertText(" ")
        case "Done": finishText()
        default: insertText(key)
        }
    }

    var filteredGames: [Game] {
        let result = games.filter { game in
            guard game.isHidden == (filter == .hidden) else { return false }
            let matches = switch filter {
            case .installed: game.status == .installed || game.status == .driveDisconnected
            case .favorites: game.isFavorite
            case .collection(let id): collections.first { $0.id == id }?.gameIDs.contains(game.id) == true
            case .all, .hidden: true
            }
            return matches && refinements.includes(game) && (query.isEmpty || game.title.localizedCaseInsensitiveContains(query))
        }
        return result.sorted { lhs, rhs in
            switch sort {
            case .playtime: if lhs.hoursPlayed != rhs.hoursPlayed { return lhs.hoursPlayed > rhs.hoursPlayed }
            case .recentlyPlayed: if lhs.lastPlayedAt != rhs.lastPlayedAt { return (lhs.lastPlayedAt ?? .distantPast) > (rhs.lastPlayedAt ?? .distantPast) }
            case .recentlyAdded: if lhs.addedAt != rhs.addedAt { return (lhs.addedAt ?? .distantPast) > (rhs.addedAt ?? .distantPast) }
            case .name: break
            }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? (lhs.id.source, lhs.id.value) < (rhs.id.source, rhs.id.value) : order == .orderedAscending
        }
    }
    var rows: [HomeRow] {
        let visible = games.filter { !$0.isHidden }
        let result: [(String, [Game])] = [
            ("Continue playing", isPreview ? ["Hades", "Cuphead", "Hollow Knight", "Dead Cells", "Stardew Valley", "Slay the Spire", "Celeste", "Outer Wilds"].compactMap { title in visible.first { $0.title == title } } : visible.filter { $0.lastPlayedAt != nil }.sorted { $0.lastPlayedAt! > $1.lastPlayedAt! }),
            ("Downloading now", visible.filter { [.queued, .downloading].contains($0.status) }.sorted { $0.status == .downloading && $1.status != .downloading }),
            ("Recently installed", isPreview ? visible.filter { $0.status == .installed && $0.hoursPlayed <= 9 } : visible.filter { $0.status == .installed && $0.installedAt != nil }.sorted { $0.installedAt! > $1.installedAt! }),
            ("Favorites", visible.filter(\.isFavorite)),
        ] + collections.filter(\.isPinned).map { collection in
            (collection.name, visible.filter { collection.gameIDs.contains($0.id) })
        }
        return result.filter { !$0.1.isEmpty }.map { name, games in
            let isContinue = name == "Continue playing"
            return HomeRow(name: name, games: isContinue ? Array(games.prefix(15)) : games, showsLibraryCard: isContinue)
        }
    }
    var focusedGame: Game? {
        if let detailID { return games.first { $0.id == detailID } ?? liveJob(for: detailID).map { game(for: $0) } }
        guard !tabsFocused else { return nil }
        if tab == .library { return filteredGames[safe: libraryCursor.index] }
        if tab == .downloads { return downloadGames[safe: downloadIndex] }
        return rows[safe: homeRow]?.games[safe: homeColumns[homeRow, default: 0]]
    }
    var detailActions: [String] {
        guard let game = focusedGame else { return [] }
        if !isPreview, let job = liveJob(for: game.id), job.kind == .uninstall, ![.completed, .cancelled].contains(job.state) {
            return ["View removal", game.isFavorite ? "Favorited" : "Favorite", "Add to collection", game.isHidden ? "Unhide" : "Hide", "Set compatibility", "View logs"]
        }
        let primary: String
        if session.phase == .awaitingCloud, session.session?.gameID == game.id { primary = "Review saves" }
        else if hasActiveSession, session.session?.gameID == game.id { primary = "Return to game" }
        else if cloudBusy(game.id) { primary = "Cloud saves" }
        else if !isPreview, let job = liveJob(for: game.id), ![.completed, .cancelled].contains(job.state) { primary = job.kind == .uninstall ? "View removal" : job.kind == .repair ? "View verification" : "View download" }
        else if gamesNeedingRepair.contains(game.id) { primary = "Verify files" }
        else { primary = switch game.status { case .installed: "Play"; case .downloading: downloadPaused ? "Resume download" : "Pause download"; case .queued: "View download"; case .driveDisconnected: "Drive disconnected"; case .notInstalled: "Install" } }
        return [primary, game.isFavorite ? "Favorited" : "Favorite", "Add to collection", game.isHidden ? "Unhide" : "Hide", "Set compatibility"] + (game.status == .installed ? (primary == "Verify files" ? ["Uninstall", "Cloud saves"] : ["Verify files", "Uninstall", "Cloud saves"]) : []) + ["View logs"]
    }
    var contextActions: [String] { ["Open game", focusedGame?.isFavorite == true ? "Unfavorite" : "Favorite", "Set compatibility", focusedGame?.isHidden == true ? "Unhide" : "Hide", "View logs", "Add to collection"] }
    var panelActions: [String] {
        switch panel {
        case .context: contextActions
        case .downloadActions(let id): downloadActions(for: id)
        case .installOffer: resolvingInstall ? [installOffer == nil ? "Cancel" : "Close"] : installOfferError != nil ? ["Cancel", "Retry"] : installOffer?.canInstall == true ? ["Cancel", "Install"] : ["Cancel", "Check space again"]
        case .filters: []
        case .compatibility: Compatibility.allCases.map(\.rawValue) + ["Edit note"]
        case .collections: collections.map(\.name) + ["New collection…"]
        case .collectionOptions(let id): ["Rename", collections.first { $0.id == id }?.isPinned == true ? "Unpin from Home" : "Pin to Home", "Delete collection…"]
        case .confirmation(let intent): ["Cancel", confirmationAction(intent)]
        case .information: ["Got it"]
        case .persistenceFailure: ["Retry saving", "Continue without saving"]
        case .signOut: ["Stay signed in", "Sign out"]
        default: []
        }
    }
    var libraryHasSummary: Bool { !query.isEmpty || refinements.isActive }
    var libraryViewportHeight: Double { libraryHasSummary ? 750 : 840 }
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
        let top = 24.0 + Double(homeRow) * 456
        homeScrollOffset = FocusViewport.reveal(offset: homeScrollOffset, itemMin: top,
            itemMax: top + 450, viewport: 840, content: 48 + Double(rows.count) * 456)
        let column = homeColumns[homeRow, default: 0]
        let left = 24.0 + Double(column) * 233
        homeRowOffsets[homeRow] = FocusViewport.reveal(offset: homeRowOffsets[homeRow, default: 0], itemMin: left,
            itemMax: left + 213, viewport: 1752, content: 48 + Double(rows[safe: homeRow]?.itemCount ?? 0) * 233)
    }
    func browseAvailableGames() {
        selectTab(.library)
        refinements = .init()
        filter = !games.isEmpty && games.allSatisfy(\.isHidden) ? .hidden : .all
        updateQuery("")
    }
    func selectTab(_ value: AppTab, focusTabs: Bool = false) { guard !resetBusy else { return }; tabsFocused = focusTabs; tab = value; detailID = nil; panel = nil; railFocused = false }
    func show(_ value: Panel) {
        guard !resetBusy else { return }
        panel = value; panelIndex = 0
        if value == .filters { filterChoiceIndex = 0; filterScrollOffset = 0; expandedGenres = false }
        if value == .search { textEditor = TextEditorState(query); keyboardError = nil }
    }
    func updateQuery(_ value: String) { query = value; libraryCursor = .init() }
    func openGame(_ game: Game) { tabsFocused = false; detailID = game.id; detailAction = 0; panel = nil }
    func toggleFavorite() {
        guard let id = focusedGame?.id, let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].isFavorite.toggle(); reconcileFocus()
    }
    func reconcileFocus() {
        libraryCursor.clamp(count: filteredGames.count)
        downloadIndex = min(downloadIndex, max(0, downloadGames.count - 1))
        homeRow = min(homeRow, max(0, rows.count - 1))
        for (i, row) in rows.enumerated() { homeColumns[i] = min(homeColumns[i, default: 0], max(0, row.itemCount - 1)) }
    }
    func perform(_ action: InputAction) {
        if performResetInput(action) { return }
        if performUninstallInput(action) { return }
        if performCloudInput(action) { return }
        if performSessionInput(action) { return }
        if panel == .controllerTest {
            if case .back = action { panel = nil }
            return
        }
        if case .options = action, panel == nil, persistenceError != nil { retryPersistence(); return }
        if panel == .filters { performFilters(action); return }
        if isEditingText {
            switch action {
            case .back: cancelText()
            case .confirm: activateKey()
            case .favorite: eraseText()
            case .context: insertText(" ")
            case .previousTab: textEditor.moveCursor(by: -1)
            case .nextTab: textEditor.moveCursor(by: 1)
            case .options: toggleSymbols()
            case .move(let direction):
                if direction == .up || direction == .down {
                    keyRow = min(max(0, keyRow + (direction == .up ? -1 : 1)), searchKeys.count - 1)
                    keyColumn = min(keyColumn, searchKeys[keyRow].count - 1)
                } else { keyColumn = min(max(0, keyColumn + (direction == .left ? -1 : 1)), searchKeys[keyRow].count - 1) }
            default: break
            }
            return
        }
        if authScreen != nil && panel == nil { performAuthentication(action); return }
        if setupScreen != nil && panel == nil { performSetup(action); return }
        if case .logs = panel {
            performLogs(action)
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
        if tabsFocused && detailID == nil {
            switch action {
            case .move(.left), .move(.right):
                let tabs = AppTab.allCases, index = tabs.firstIndex(of: tab) ?? 0
                let delta: Int
                if case .move(.left) = action { delta = -1 } else { delta = 1 }
                let next = min(max(0, index + delta), tabs.count - 1)
                selectTab(tabs[next], focusTabs: true)
                return
            case .move(.down), .confirm, .back: tabsFocused = false; return
            case .move(.up), .favorite, .context, .options, .previousPage, .nextPage: return
            default: break
            }
        }
        switch action {
        case .move(let direction): move(direction)
        case .holdHome: break // Handled by the session focus scope above.
        case .confirm:
            if detailID != nil { activateDetail() }
            else if tab == .settings { activateSetting() }
            else if tab == .downloads {
                if !isPreview, let game = focusedGame { show(.downloadActions(game.id)) }
                else if focusedGame?.status == .downloading { downloadPaused.toggle() }
                else if let game = focusedGame { openGame(game) }
                else { browseAvailableGames() }
            }
            else if tab == .library && railFocused {
                if libraryRailIndex == libraryFilters.count { beginText(.newCollection(nil)) }
                else { railFocused = false }
            }
            else if let game = focusedGame { openGame(game) }
            else if tab == .home || tab == .library {
                if !isPreview && games.isEmpty && identity == nil && query.isEmpty { beginSignIn() } else { browseAvailableGames() }
            }
        case .back:
            if detailID != nil { detailID = nil }
            else if !query.isEmpty { updateQuery("") }
            else { selectTab(.home) }
        case .favorite: if !(tab == .library && railFocused) { toggleFavorite() }
        case .context:
            if tab == .downloads && detailID == nil, let id = focusedGame?.id { show(.downloadActions(id)) }
            else if tab == .library && railFocused {
                if libraryRailIndex < libraryFilters.count, case .collection(let id) = filter { show(.collectionOptions(id)) }
            } else if focusedGame != nil { show(.context) }
        case .options: if tab == .library && detailID == nil { show(.filters) }
        case .search: selectTab(.library); show(.search)
        case .home: selectTab(.home); homeRow = 0; homeColumns[0] = 0
        case .previousTab, .nextTab:
            let tabs = AppTab.allCases, index = tabs.firstIndex(of: tab) ?? 0
            selectTab(tabs[(index + (action.isNextTab ? 1 : tabs.count - 1)) % tabs.count], focusTabs: tabsFocused)
        case .previousPage: for _ in 0..<2 { move(.up, allowsTabFocus: false) }
        case .nextPage: for _ in 0..<2 { move(.down) }
        }
    }
    private func move(_ direction: Direction, allowsTabFocus: Bool = true) {
        if detailID != nil {
            detailAction = min(max(0, detailAction + (direction == .left ? -1 : direction == .right ? 1 : 0)), detailActions.count - 1)
        } else if tab == .home {
            if direction == .up && homeRow == 0 && allowsTabFocus { tabsFocused = true; return }
            if direction == .up || direction == .down { homeRow = min(max(0, homeRow + (direction == .up ? -1 : 1)), max(0, rows.count - 1)) }
            else { homeColumns[homeRow] = min(max(0, homeColumns[homeRow, default: 0] + (direction == .left ? -1 : 1)), max(0, (rows[safe: homeRow]?.itemCount ?? 0) - 1)) }
        } else if tab == .library {
            if direction == .up && allowsTabFocus && (railFocused ? libraryRailIndex == 0 : libraryCursor.index < 6) { tabsFocused = true; return }
            if railFocused {
                if direction == .right { railFocused = false }
                else if direction == .up || direction == .down {
                    libraryRailIndex = min(max(0, libraryRailIndex + (direction == .up ? -1 : 1)), libraryFilters.count)
                    if libraryRailIndex < libraryFilters.count { filter = libraryFilters[libraryRailIndex] }
                }
            } else if !libraryCursor.move(direction, count: filteredGames.count, columns: 6), direction == .left { railFocused = true }
        } else if tab == .downloads {
            if direction == .up && downloadIndex == 0 && allowsTabFocus { tabsFocused = true; return }
            if direction == .up || direction == .down {
                downloadIndex = min(max(0, downloadIndex + (direction == .up ? -1 : 1)), max(0, downloadGames.count - 1))
            }
        } else if tab == .settings {
            if direction == .up && allowsTabFocus && (settingsRailFocused ? settingsSection == 0 : settingsIndex == 0) { tabsFocused = true; return }
            if direction == .left { settingsRailFocused = true }
            else if direction == .right { settingsRailFocused = false }
            else if settingsRailFocused { settingsSection = min(max(0, settingsSection + (direction == .up ? -1 : 1)), 4); settingsIndex = 0 }
            else { settingsIndex = min(max(0, settingsIndex + (direction == .up ? -1 : 1)), settingsSection == 1 || settingsSection == 2 ? 3 : settingsSection == 4 ? 2 : 0) }
        }
    }
    func activateDetail() {
        guard let label = detailActions[safe: detailAction] else { return }
        switch label {
        case "Cloud saves", "Review saves": if let id = focusedGame?.id { showCloud(id) }
        case "Play": if let id = focusedGame?.id { beginPlay(id) }
        case "Return to game": returnToGame()
        case "Favorite", "Favorited": toggleFavorite()
        case "Hide", "Unhide": hideFocused()
        case "Set compatibility": show(.compatibility)
        case "Add to collection": if let id = focusedGame?.id { show(.collections(id)) }
        case "View logs": if let id = focusedGame?.id { show(.logs(id)) }
        case "Verify files":
            if !isPreview, let id = focusedGame?.id { beginVerification(id) }
            else { show(.information("Verification checks the installed game and repairs damaged files when connected.")) }
        case "Uninstall":
            if let id = focusedGame?.id { beginUninstall(id) }
        case "Install":
            if !isPreview, let id = focusedGame?.id { beginInstall(id) }
            else if let id = focusedGame?.id { show(.confirmation(.install(id))) }
        case "Pause download", "Resume download": downloadPaused.toggle()
        case "View download", "View verification", "View removal":
            if let id = focusedGame?.id { revealDownloadHistory(for: id) }
        default: show(.information(isPreview ? "This is the design preview. \(label) will connect to the real game service in a later milestone. No game files are changed." : "\(label) is still being implemented. Your game files have been kept."))
        }
    }
    func activatePanel() {
        guard let label = panelActions[safe: panelIndex] else { return }
        switch panel {
        case .installOffer(let id):
            if panelIndex == 0 { panel = nil }
            else if installOfferError != nil || installOffer?.canInstall != true { beginInstall(id) }
            else { confirmInstall() }
        case .signOut:
            if panelIndex == 1 { signOut() } else { panel = nil }
        case .persistenceFailure:
            if panelIndex == 0 { retryPersistence() } else { panel = nil }
        case .context:
            if label == "Open game", let game = focusedGame { openGame(game) }
            else if label == "Favorite" || label == "Unfavorite" { toggleFavorite(); panel = nil }
            else if label == "Set compatibility" { show(.compatibility) }
            else if label == "Hide" || label == "Unhide" { hideFocused(); panel = nil }
            else if label == "Add to collection", let id = focusedGame?.id { show(.collections(id)) }
            else if let id = focusedGame?.id { show(.logs(id)) }
        case .compatibility:
            if label == "Edit note", let id = focusedGame?.id { beginText(.compatibilityNote(id)) }
            else if let id = focusedGame?.id, let i = games.firstIndex(where: { $0.id == id }), let rating = Compatibility(rawValue: label) { games[i].compatibility = rating }
        case .collections(let gameID):
            if panelIndex == collections.count { beginText(.newCollection(gameID)) }
            else if collections[panelIndex].gameIDs.contains(gameID) { collections[panelIndex].gameIDs.remove(gameID) }
            else { collections[panelIndex].gameIDs.insert(gameID) }
            reconcileFocus()
        case .collectionOptions(let id):
            guard let index = collections.firstIndex(where: { $0.id == id }) else { panel = nil; return }
            if label == "Rename" { beginText(.renameCollection(id)) }
            else if label == "Delete collection…" { show(.confirmation(.deleteCollection(id))) }
            else { collections[index].isPinned.toggle(); reconcileFocus(); panel = nil }
        case .downloadActions(let id): activateDownloadAction(label, id: id)
        case .confirmation(let intent):
            if panelIndex == 0 { panel = nil }
            else { confirm(intent) }
        default: panel = nil
        }
    }
    private func hideFocused() {
        guard let id = focusedGame?.id, let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].isHidden.toggle(); detailID = nil; reconcileFocus()
    }
    func activateSetting() {
        if settingsRailFocused { settingsRailFocused = false; return }
        if settingsSection == 0 && !isPreview {
            if identity == nil { beginSignIn() }
            else { show(.signOut) }
        }
        else if settingsSection == 1 && settingsIndex == 0 && !isPreview { refreshLibrary() }
        else if settingsSection == 1 && settingsIndex == 1 { openVolumeSetup() }
        else if settingsSection == 1 && settingsIndex == 3 { openRuntimeSetup() }
        else if settingsSection == 2 && settingsIndex == 0 { onboarding = false; setupScreen = .display; setupIndex = displays.firstIndex(where: { $0.id == preferredDisplay?.id }) ?? 0 }
        else if settingsSection == 2 && settingsIndex == 1 { requestFullscreen() }
        else if settingsSection == 2 && settingsIndex == 2 { toggleStartInFullscreen() }
        else if settingsSection == 2 && settingsIndex == 3 { reducedMotion.toggle() }
        else if settingsSection == 1 && settingsIndex == 2 { downloadWhilePlaying.toggle() }
        else if settingsSection == 3 { openControllerTest() }
        else if settingsSection == 4 && settingsIndex == 1 { revealLogsFolder() }
        else if settingsSection == 4 && settingsIndex == 2 { showResetAppData() }
        else if settingsSection == 4 { show(.information("Big Screen \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")\n\nCrossOver \(runtimeInfo?.version ?? "not detected") · Template \(runtimeInfo?.templateVersion ?? "not prepared")")) }
        else { show(.information(isPreview ? "The design preview uses sample games. Launch without --preview to connect your account and set up your Mac." : "This setting is still being implemented.")) }
    }
    func openControllerTest() {
        controllerTest = ControllerTestState()
        controllerTest.update(connectedControllers, at: ProcessInfo.processInfo.systemUptime)
        show(.controllerTest)
    }
    func receiveControllers(_ values: [ControllerSnapshot], at time: Double) {
        if connectedControllers != values { connectedControllers = values }
        guard panel == .controllerTest else { return }
        if controllerTest.update(values, at: time) { panel = nil }
    }
    func performController(_ action: InputAction) {
        keyboardNavigation = false
        guard panel != .controllerTest else { return }
        perform(action)
    }
}
private extension InputAction { var isNextTab: Bool { if case .nextTab = self { true } else { false } } }
extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
