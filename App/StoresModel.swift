import AppKit
import Domain
import Installs
import Focus
import Sources

enum StoreSettingsRow: Equatable { case account(String), signOut(String), preferMac, thisMac, addedGames, folders }

/// Names and glyphs for stores. Store IDs never appear in the UI.
enum StoreNames {
    static func name(_ id: String) -> String {
        switch id { case SourceID.steam: "Steam"; case SourceID.local: "This Mac"; case SourceID.epic: "Epic Games"; default: id.capitalized }
    }
    static func symbol(_ id: String) -> String {
        switch id { case SourceID.local: "desktopcomputer"; case SourceID.epic: "shippingbox"; default: "bag" }
    }
}

extension LibraryModel {
    // MARK: Stores in the library

    /// Stores that have at least one game, in registry order.
    var storesWithGames: [String] {
        let present = Set(games.map(\.id.source))
        var ordered = sources.all.map(\.id) + [SourceID.steam, SourceID.local]
        ordered += present.subtracting(ordered).sorted()
        var seen = Set<String>()
        return ordered.filter { present.contains($0) && seen.insert($0).inserted }
    }
    /// Store glyphs and store rail entries only matter once a second store has games.
    var showsStores: Bool { storesWithGames.count > 1 }
    func runsAsLabel(_ game: Game) -> String {
        if let platform = game.installedPlatform { return platform == .windows ? "Windows · CrossOver" : "macOS" }
        let platforms = Set(game.platforms)
        if platforms == [.windows, .macOS] { return "macOS or Windows" }
        if platforms == [.macOS] { return "macOS" }
        return "Windows · CrossOver"
    }
    /// A Steam game with the same title, for This Mac apps that need the Steam client.
    func steamVersion(of game: Game) -> Game? {
        guard game.isExternal else { return nil }
        return games.first { $0.id.source == SourceID.steam && $0.title.localizedCaseInsensitiveCompare(game.title) == .orderedSame }
    }
    var steamClientNotice: String? {
        guard let game = focusedGame, game.isExternal, game.usesSteamClient else { return nil }
        return "This game uses Steam. It may close or ask for the Steam app when started from Playden."
            + (steamVersion(of: game) != nil ? " You can install its Mac version from Steam instead." : "")
    }

    // MARK: Settings → Stores

    /// Nothing is in the library yet: no store is connected and no Mac game was added.
    var needsGames: Bool { !isPreview && games.isEmpty }
    func openStoreSettings() {
        selectTab(.settings); settingsSection = 0; settingsIndex = 0; settingsRailFocused = false
    }
    /// With Steam as the only store, the empty library leads straight to sign-in.
    func startAddingGames() { if localSource == nil { beginSignIn() } else { openStoreSettings() } }
    var addGamesTitle: String { localSource == nil ? "Sign in to Steam" : "Add games" }
    var addGamesMessage: String { localSource == nil ? "Sign in to Steam to see your library." : "Sign in to Steam, or add games that are already on this Mac." }

    var storeSettingsRows: [StoreSettingsRow] {
        guard !isPreview else { return [.account(SourceID.steam), .preferMac, .thisMac, .addedGames, .folders] }
        var rows: [StoreSettingsRow] = []
        if let source { rows += [.account(source.id)] + (identity == nil ? [] : [.signOut(source.id)]) + [.preferMac] }
        for other in otherAccountSources {
            rows += [.account(other.id)] + (account(other.id).identity == nil ? [] : [.signOut(other.id)])
        }
        if localSource != nil { rows += [.thisMac, .addedGames, .folders] }
        return rows
    }
    /// Title, status and action for a store's account row in Settings.
    func accountRow(_ id: String) -> (String, String, String) {
        let account = account(id)
        let status = account.syncError ?? (isPreview ? "Using designer preview data"
            : account.identity.map { "Signed in as \($0.displayName)" } ?? "Sign in to see your games")
        return (accountName(id), status, account.identity == nil ? "Sign in" : "Sign in again")
    }
    var thisMacSummary: String {
        let count = games.filter { $0.id.source == SourceID.local }.count
        if let error = scanErrors[SourceID.local] { return error }
        return count == 0 ? "Add Mac games that are already installed" : "\(count) game\(count == 1 ? "" : "s") on this Mac"
    }
    func activateStoreSetting() {
        guard let row = storeSettingsRows[safe: settingsIndex] else { return }
        switch row {
        case .account(let id): if isPreview { show(.information("\(accountName(id)) sign-in is available in the live app.")) } else { beginSignIn(id) }
        case .signOut(let id): signOutSourceID = id; show(.signOut)
        case .preferMac:
            preferMacVersions.toggle()
            try? updateSetupPreferences { $0.preferMacVersions = preferMacVersions }
        case .thisMac: if isPreview { show(.information("Adding Mac games is available in the live app.")) } else { showLocalGames() }
        case .addedGames: showAddedGames()
        case .folders: if isPreview { show(.information("Watched folders are available in the live app.")) } else { showLocalFolders() }
        }
    }

    // MARK: Added games

    /// Every This Mac game, added by hand or found in a watched folder, by title.
    var addedLocalGames: [Game] {
        games.filter { $0.id.source == SourceID.local }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var addedGamesSummary: String {
        let count = addedLocalGames.count
        return count == 0 ? "No Mac games in your library yet" : "\(count) game\(count == 1 ? "" : "s") · pick ones to remove from Playden"
    }
    func showAddedGames() {
        localRemovalSelection = []; localMessage = nil
        show(.localAdded)
        reloadRemovedGames()
    }
    func reloadRemovedGames() {
        guard let localSource else { return }
        Task { [weak self] in
            let removed = (try? await localSource.removedGames()) ?? []
            self?.localRemovedGames = removed
        }
    }
    /// The panel lists games in the library, then the remove action once some are checked, then removed games to restore.
    private var addedGamesRemoveAction: [String] {
        let count = localRemovalSelection.count
        return count == 0 ? [] : ["Remove \(count) game\(count == 1 ? "" : "s")"]
    }
    var addedGamesActions: [String] {
        let rows = addedLocalGames.map { game in
            game.title + (game.status == .missing ? " · Missing" : game.status == .driveDisconnected ? " · Not connected" : "")
        }
        let restores = localRemovedGames.map { "Restore \($0.title)" + ($0.found ? "" : " · Not found") }
        return rows + addedGamesRemoveAction + restores + ["Done"]
    }
    func activateAddedGames(_ index: Int) {
        let listed = addedLocalGames
        if let game = listed[safe: index] {
            if localRemovalSelection.remove(game.id) == nil { localRemovalSelection.insert(game.id) }
            return
        }
        let removeIndex = listed.count, restoreStart = listed.count + addedGamesRemoveAction.count
        if !addedGamesRemoveAction.isEmpty && index == removeIndex {
            removeFromLibrary(Array(localRemovalSelection), returningToList: true); return
        }
        guard let removed = localRemovedGames[safe: index - restoreStart] else { panel = nil; return }
        restoreRemovedGame(removed)
    }
    func restoreRemovedGame(_ removed: LocalSource.RemovedGame) {
        guard let localSource else { return }
        Task { [weak self] in
            do { try await localSource.restore(removed.id) } catch {
                self?.localMessage = (error as? OperationFailure)?.reason ?? error.localizedDescription; return
            }
            guard let self else { return }
            self.localMessage = "Restored \(removed.title)."
            self.refreshScannedLibraries()
            self.localRemovedGames = (try? await localSource.removedGames()) ?? []
            await self.scanTask?.value
            if self.panel == .localAdded { self.panelIndex = min(self.panelIndex, max(0, self.addedGamesActions.count - 1)) }
        }
    }

    // MARK: This Mac

    func showLocalGames(relocating id: GameID? = nil) {
        guard let localSource else { return }
        localCandidates = []; localBusy = true; localMessage = nil
        show(.localGames(id))
        Task { [weak self] in
            let found = (try? await localSource.suggestions()) ?? []
            guard let self, self.panel == .localGames(id) else { return }
            self.localCandidates = found; self.localBusy = false
            if found.isEmpty { self.localMessage = "No games found in your Applications or Games folders. Choose an app to add one from anywhere." }
        }
    }
    static let browseForAppTitle = "Choose an app…"
    /// Choosing any app comes first and works while suggestions are still loading; suggestions follow.
    func localGamesActions(relocating id: GameID?) -> [String] {
        let suggestions = localBusy ? [] : localCandidates.map { $0.added && id == nil ? $0.app.title + " · Added" : $0.app.title }
        return [Self.browseForAppTitle] + suggestions + ["Done"]
    }
    func activateLocalGames(_ index: Int, relocating id: GameID?) {
        let actions = localGamesActions(relocating: id)
        guard actions.indices.contains(index) else { return }
        if index == actions.count - 1 { panel = nil; return }
        if index == 0 { browseForApp(relocating: id); return }
        guard let candidate = localCandidates[safe: index - 1] else { return }
        if candidate.added && id == nil { return }
        addLocalApp(candidate.app.url, origin: .suggested, relocating: id)
    }
    func browseForApp(relocating id: GameID?) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.applicationBundle]; open.allowsMultipleSelection = false
        open.directoryURL = URL(fileURLWithPath: "/Applications"); open.prompt = id == nil ? "Add game" : "Locate"
        guard open.runModal() == .OK, let url = open.url else { return }
        addLocalApp(url, origin: .manual, relocating: id)
    }
    private func addLocalApp(_ url: URL, origin: LocalLibrary.Entry.Origin, relocating id: GameID?) {
        guard let localSource else { return }
        Task { [weak self] in
            do {
                if let id { try await localSource.relocate(id, to: url) } else { try await localSource.add(url, origin: origin) }
                guard let self else { return }
                self.refreshScannedLibraries()
                if id != nil { self.panel = nil; return }
                if let index = self.localCandidates.firstIndex(where: { $0.app.url == url }) {
                    self.localCandidates[index] = .init(app: self.localCandidates[index].app, added: true)
                } else if let app = LocalAppBundle(url: url) {
                    self.localCandidates.append(.init(app: app, added: true))
                }
                self.localMessage = "Added \(LocalAppBundle(url: url)?.title ?? url.deletingPathExtension().lastPathComponent)."
            } catch { self?.localMessage = (error as? OperationFailure)?.reason ?? error.localizedDescription }
        }
    }
    func showLocalFolders() {
        guard localSource != nil else { return }
        show(.localFolders); reloadLocalFolders()
    }
    func reloadLocalFolders() {
        guard let localSource else { return }
        Task { [weak self] in
            let folders = (try? await localSource.folders()) ?? []
            self?.localFolderSummaries = folders
        }
    }
    var localFolderActions: [String] {
        localFolderSummaries.map { summary in
            summary.folder.lastKnownPath.lastPathComponent + " · \(summary.gameCount) game\(summary.gameCount == 1 ? "" : "s")" + (summary.available ? "" : " · Not connected")
        } + ["Add folder…", "Rescan now", "Done"]
    }
    func activateLocalFolders(_ index: Int) {
        guard let label = localFolderActions[safe: index] else { return }
        switch label {
        case "Done": panel = nil
        case "Rescan now": refreshScannedLibraries(); reloadLocalFoldersAfterScan()
        case "Add folder…":
            let open = NSOpenPanel()
            open.canChooseDirectories = true; open.canChooseFiles = false; open.allowsMultipleSelection = false; open.prompt = "Watch folder"
            guard open.runModal() == .OK, let url = open.url, let localSource else { return }
            Task { [weak self] in
                do { try await localSource.addFolder(url) } catch { self?.show(.information((error as? OperationFailure)?.reason ?? error.localizedDescription)); return }
                self?.refreshScannedLibraries(); self?.reloadLocalFoldersAfterScan()
            }
        default:
            if let folder = localFolderSummaries[safe: index]?.folder { show(.localFolderOptions(folder.id)) }
        }
    }
    func localFolderOptionsTitle(_ id: UUID) -> String {
        "Stop watching \(localFolderSummaries.first { $0.id == id }?.folder.lastKnownPath.lastPathComponent ?? "this folder")?"
    }
    func activateLocalFolderOption(_ label: String, id: UUID) {
        guard label != "Cancel", let localSource else { showLocalFolders(); return }
        Task { [weak self] in
            try? await localSource.removeFolder(id, removingGames: label == "Remove its games too")
            self?.refreshScannedLibraries(); self?.showLocalFolders(); self?.reloadLocalFoldersAfterScan()
        }
    }
    private func reloadLocalFoldersAfterScan() {
        Task { [weak self] in
            await self?.scanTask?.value
            self?.reloadLocalFolders()
        }
    }
    func removeFromLibrary(_ id: GameID) { removeFromLibrary([id], returningToList: false) }
    /// The apps stay on the Mac; adding one again brings its playtime back.
    func removeFromLibrary(_ ids: [GameID], returningToList: Bool) {
        guard let localSource else { return }
        Task { [weak self] in
            for id in ids {
                do { try await localSource.remove(id) } catch { self?.show(.information(error.localizedDescription)); return }
            }
            guard let self else { return }
            if let detail = self.detailID, ids.contains(detail) { self.detailID = nil }
            self.localRemovalSelection.subtract(ids)
            self.refreshScannedLibraries()
            guard returningToList else { self.panel = nil; return }
            self.localRemovedGames = (try? await localSource.removedGames()) ?? []
            await self.scanTask?.value
            if self.panel == .localAdded { self.panelIndex = min(self.panelIndex, max(0, self.addedGamesActions.count - 1)) }
        }
    }
    func renameGame(_ id: GameID, to value: String) {
        guard let catalog, let index = games.firstIndex(where: { $0.id == id }) else { return }
        var edits = edits(for: games[index])
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        edits.titleOverride = trimmed.isEmpty ? nil : trimmed
        do { try catalog.saveEdits(edits, for: id); reloadCatalog() } catch { show(.information(error.localizedDescription)) }
    }

    // MARK: Platform choice

    /// The build an install offer starts with: the player's last choice, then the preference.
    func defaultInstallPlatform(_ id: GameID) -> GamePlatform {
        guard let game = games.first(where: { $0.id == id }), game.platforms.contains(.macOS) else { return .windows }
        guard game.platforms.contains(.windows) else { return .macOS }
        return storedEdits[id]?.preferredPlatform ?? (preferMacVersions ? .macOS : .windows)
    }
    /// Only a game that isn't installed yet chooses its build before the offer; an installed one switches instead.
    func offersPlatformChoice(_ id: GameID) -> Bool {
        guard let game = games.first(where: { $0.id == id }) else { return false }
        return game.installedPlatform == nil && Set(game.platforms) == [.windows, .macOS]
    }
    /// The order the version picker lists builds in.
    var installPlatformChoices: [GamePlatform] { [.windows, .macOS] }
    /// Install starts with the version picker when the game has both builds.
    func startInstall(_ id: GameID) {
        guard offersPlatformChoice(id) else { beginInstall(id); return }
        showPlatformPicker(id, focusing: defaultInstallPlatform(id))
    }
    func showPlatformPicker(_ id: GameID, focusing platform: GamePlatform) {
        show(.platformPicker(id))
        panelIndex = installPlatformChoices.firstIndex(of: platform) ?? 0
    }
    /// "Choose volume…" sits on the destination row above the other buttons.
    func moveInstallOfferFocus(_ direction: Direction) {
        let actions = panelActions
        guard let volume = actions.firstIndex(of: "Choose volume…") else { return }
        let buttons = actions.indices.filter { $0 != volume }
        switch direction {
        case .up: panelIndex = volume
        case .down: if panelIndex == volume { panelIndex = buttons.last ?? 0 }
        case .left, .right:
            guard let position = buttons.firstIndex(of: panelIndex) else { return }
            panelIndex = buttons[min(max(0, position + (direction == .left ? -1 : 1)), buttons.count - 1)]
        }
    }
    func otherPlatform(for id: GameID) -> GamePlatform? {
        guard let game = games.first(where: { $0.id == id }), Set(game.platforms) == [.windows, .macOS] else { return nil }
        return game.installedPlatform.map { $0 == .windows ? .macOS : .windows } ?? (installPlatform == .windows ? .macOS : .windows)
    }
    func rememberInstallPlatform(_ id: GameID) {
        guard let catalog, let game = games.first(where: { $0.id == id }), game.platforms.count > 1 else { return }
        var edits = edits(for: game); edits.preferredPlatform = installPlatform
        storedEdits[id] = edits
        try? catalog.saveEdits(edits, for: id)
    }
    /// Removes the installed build first; the other build is offered once removal finishes.
    func beginPlatformSwitch(_ id: GameID, to platform: GamePlatform) {
        pendingPlatformSwitch[id] = (platform, .now)
        beginUninstall(id)
    }
    func completePendingPlatformSwitches(_ jobs: [JobRecord]) {
        for (id, pending) in pendingPlatformSwitch {
            // Only the removal this switch started counts; a cancelled review starts none.
            guard let job = jobs.last(where: { $0.gameID == id && $0.kind == .uninstall && $0.createdAt >= pending.requestedAt }) else { continue }
            let platform = pending.platform
            if job.state == .completed {
                pendingPlatformSwitch[id] = nil
                beginInstall(id, volume: gamesVolume, platform: platform)
            } else if job.state == .cancelled { pendingPlatformSwitch[id] = nil }
        }
    }
}

// MARK: - Screenshot fixtures

extension LibraryModel {
    /// Used only by the explicit screenshot command; the apps are ones every Mac has.
    func configureStoresSnapshot(_ screen: String) {
        func local(_ value: String, _ title: String, _ path: String, status: InstallStatus = .installed) -> Game {
            var game = Game(id: GameID(source: SourceID.local, value: value), title: title, status: status, hoursPlayed: value == "chess" ? 3 : 0)
            game.platforms = [.macOS]; game.installedPlatform = .macOS; game.isExternal = true
            game.appURL = URL(fileURLWithPath: path); game.addedAt = .now; game.installedAt = .now
            return game
        }
        var chess = local("chess", "Chess", "/System/Applications/Chess.app")
        chess.usesSteamClient = screen == "game-local-steam-warning"
        games += [chess, local("booth", "Photo Booth", "/System/Applications/Photo Booth.app", status: screen == "game-local-missing" ? .missing : .installed)]
        if let index = games.firstIndex(where: { $0.title == "TUNIC" }) { games[index].platforms = [.windows, .macOS] }
        switch screen {
        case "library-stores":
            selectTab(.library); filter = .all
            if let index = filteredGames.firstIndex(where: { $0.title == "Chess" }) { libraryCursor = GridCursor(index: index) }
        case "library-filters-platform":
            selectTab(.library); show(.filters)
            if let chip = filterLayout.chips.first(where: { $0.choice == .platform(.macOS) }) { filterChoiceIndex = chip.id; revealFilterFocus() }
        case "game-local", "game-local-steam-warning":
            selectTab(.library); openGame(chess)
        case "game-local-missing":
            selectTab(.library); if let game = games.first(where: { $0.title == "Photo Booth" }) { openGame(game) }
        case "settings-stores":
            selectTab(.settings); settingsSection = 0; settingsIndex = 2; settingsRailFocused = false
        case "local-picker":
            selectTab(.settings); settingsSection = 0
            panel = .localGames(nil); panelIndex = 0; localBusy = false
            localCandidates = ["/System/Applications/Chess.app", "/System/Applications/Photo Booth.app", "/System/Applications/Stickies.app"]
                .compactMap { LocalAppBundle(url: URL(fileURLWithPath: $0)) }.enumerated().map { .init(app: $0.element, added: $0.offset == 0) }
        case "settings-local-folders":
            selectTab(.settings); settingsSection = 0
            panel = .localFolders; panelIndex = 0
            localFolderSummaries = [
                .init(folder: .init(bookmark: nil, lastKnownPath: URL(fileURLWithPath: "/Applications/Games")), gameCount: 4, available: true),
                .init(folder: .init(bookmark: nil, lastKnownPath: URL(fileURLWithPath: "/Volumes/Games/Mac")), gameCount: 7, available: false),
            ]
        case "setup-add-games":
            onboarding = true; setupScreen = .games; setupIndex = 0
        default: break
        }
    }
}
