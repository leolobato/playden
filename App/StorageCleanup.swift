import Foundation
import Domain
import Focus
import Input

enum StorageSort: String, CaseIterable { case size = "Size", lastPlayed = "Last played" }

/// Volume cards, the sort control, game rows, then Done and Delete.
enum StorageFocus: Equatable { case volumes, sort, game(Int), done, delete }

struct StorageGameRow: Identifiable, Equatable {
    let id: GameID
    var title: String
    var bytes: Int64
    var lastPlayedAt: Date?
    var volumeID: String
    /// Why the game can't be removed from here right now.
    var blocker: String?
}

struct StorageCleanupState {
    var rows: [StorageGameRow] = []
    var volumeID: String?
    var sort: StorageSort = .size
    var selection: Set<GameID> = []
    var focus: StorageFocus = .volumes
    var confirming = false
    var confirmIndex = 0
    var progress: String?
    var message: String?
    /// Games whose saves could not be synced; each opens the uninstall dialog after the sheet closes.
    var decisions: [(id: GameID, review: UninstallReview, message: String)] = []
    var busy: Bool { progress != nil }
}

extension LibraryModel {
    static let previewStorageVolumes = [
        GamesVolume(id: "preview", name: "VM", mountURL: URL(fileURLWithPath: "/Volumes/VM"),
                    gamesRoot: URL(fileURLWithPath: "/Volumes/VM/Playden/games"), freeBytes: 1_350_000_000_000, totalBytes: 2_000_000_000_000),
        GamesVolume(id: "preview-internal", name: "Macintosh HD", mountURL: URL(fileURLWithPath: "/"),
                    gamesRoot: URL(fileURLWithPath: "/Users/Shared/Playden/games"), freeBytes: 182_000_000_000, totalBytes: 994_000_000_000)
    ]

    /// Connected volumes that hold games or take new installs. Disconnected drives are left out:
    /// their games can't be removed until the drive returns.
    var storageVolumes: [GamesVolume] {
        let volumes = isPreview ? Self.previewStorageVolumes : availableVolumes
        let used = Set(storageCleanup.rows.map(\.volumeID)), enabled = Set(enabledInstallVolumes.map(\.volumeID))
        return volumes.filter { used.contains($0.id) || enabled.contains($0.id) }
    }
    var storageVolume: GamesVolume? {
        storageVolumes.first { $0.id == storageCleanup.volumeID } ?? storageVolumes.first
    }
    /// The selected volume's games in the chosen order. Never played sorts before the oldest session.
    var storageRows: [StorageGameRow] {
        guard let volumeID = storageVolume?.id else { return [] }
        return storageCleanup.rows.filter { $0.volumeID == volumeID }.sorted { lhs, rhs in
            switch storageCleanup.sort {
            case .size: if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            case .lastPlayed:
                if lhs.lastPlayedAt != rhs.lastPlayedAt { return (lhs.lastPlayedAt ?? .distantPast) < (rhs.lastPlayedAt ?? .distantPast) }
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
    func storageBytes(on volumeID: String) -> Int64 {
        storageCleanup.rows.filter { $0.volumeID == volumeID }.reduce(0) { $0 + $1.bytes }
    }
    /// Checked games on the shown volume that can still be removed, in list order.
    var storageSelectedRows: [StorageGameRow] {
        storageRows.filter { storageCleanup.selection.contains($0.id) && $0.blocker == nil }
    }
    var storageSelectedBytes: Int64 { storageSelectedRows.reduce(0) { $0 + $1.bytes } }
    var storageSettingSummary: String {
        let count = isPreview ? games.filter { $0.knownInstalledBytes != nil }.count
            : (try? catalog?.snapshot().entries.filter { $0.installation.map { !$0.isExternal } == true }.count) ?? 0
        return count == 0 ? "Installed games appear here with their size" : "\(count) installed game\(count == 1 ? "" : "s") · free up space by size or last played"
    }

    func showStorageCleanup() {
        storageCleanup = StorageCleanupState(volumeID: gamesVolume?.volumeID)
        reloadStorageRows()
        show(.storage)
        storageCleanup.focus = storageRows.isEmpty ? .done : .game(0)
        Task { [weak self] in
            await self?.refreshInstallVolumes()
            self?.clampStorageFocus()
        }
    }

    func reloadStorageRows() {
        let activeJobs = Set(latestInstallJobs.filter { ![.completed, .cancelled, .failed].contains($0.state) }.map(\.gameID))
        let playing = hasActiveSession ? session.session?.gameID : nil
        func blocker(_ id: GameID) -> String? {
            if id == playing { return "Playing" }
            if activeJobs.contains(id) { return "In Downloads" }
            return nil
        }
        if isPreview {
            let installed = games.filter { $0.knownInstalledBytes != nil }
            storageCleanup.rows = installed.enumerated().map { index, game in
                .init(id: game.id, title: game.title, bytes: game.knownInstalledBytes ?? 0, lastPlayedAt: game.lastPlayedAt,
                      volumeID: Self.previewStorageVolumes[index % 4 == 3 ? 1 : 0].id, blocker: game.status == .downloading ? "In Downloads" : nil)
            }
        } else {
            let entries = (try? catalog?.snapshot().entries) ?? []
            storageCleanup.rows = entries.compactMap { entry in
                guard let installation = entry.installation, !installation.isExternal else { return nil }
                let game = games.first { $0.id == entry.id }
                return .init(id: entry.id, title: game?.title ?? installation.game.title, bytes: max(0, installation.installedBytes),
                             lastPlayedAt: entry.lastPlayedAt, volumeID: installation.location.volumeID, blocker: blocker(entry.id))
            }
        }
        let present = Set(storageCleanup.rows.map(\.id))
        storageCleanup.selection = storageCleanup.selection.filter { present.contains($0) }
        clampStorageFocus()
    }

    func clampStorageFocus() {
        if case .game(let index) = storageCleanup.focus {
            storageCleanup.focus = storageRows.isEmpty ? .done : .game(min(index, storageRows.count - 1))
        }
        if storageCleanup.focus == .delete && storageSelectedRows.isEmpty { storageCleanup.focus = .done }
    }

    func selectStorageVolume(offset: Int) {
        let volumes = storageVolumes
        guard !volumes.isEmpty else { return }
        let current = volumes.firstIndex { $0.id == storageVolume?.id } ?? 0
        let next = min(max(0, current + offset), volumes.count - 1)
        guard next != current else { return }
        storageCleanup.volumeID = volumes[next].id
        // Checked games stay checked only on the volume they were picked from.
        storageCleanup.selection = []
        clampStorageFocus()
    }

    func toggleStorageSort() {
        storageCleanup.sort = storageCleanup.sort == .size ? .lastPlayed : .size
        if case .game = storageCleanup.focus, !storageRows.isEmpty { storageCleanup.focus = .game(0) }
    }

    func toggleStorageSelection(_ id: GameID) {
        guard let row = storageRows.first(where: { $0.id == id }), row.blocker == nil else { return }
        if storageCleanup.selection.remove(id) == nil { storageCleanup.selection.insert(id) }
    }

    func performStorageInput(_ action: InputAction) -> Bool {
        guard panel == .storage else { return false }
        if storageCleanup.busy {
            if case .back = action { storageCleanupTask?.cancel() }
            return true
        }
        if storageCleanup.confirming {
            switch action {
            case .move(.left), .move(.up): storageCleanup.confirmIndex = 0
            case .move(.right), .move(.down): storageCleanup.confirmIndex = 1
            case .confirm: if storageCleanup.confirmIndex == 1 { deleteSelectedStorageGames() } else { storageCleanup.confirming = false }
            case .back: storageCleanup.confirming = false
            default: break
            }
            return true
        }
        switch action {
        case .move(let direction): moveStorageFocus(direction)
        case .confirm: activateStorageFocus()
        case .back: panel = nil
        case .options: toggleStorageSort()
        case .previousTab: selectStorageVolume(offset: -1)
        case .nextTab: selectStorageVolume(offset: 1)
        default: break
        }
        return true
    }

    func moveStorageFocus(_ direction: Direction) {
        let count = storageRows.count, canDelete = !storageSelectedRows.isEmpty
        var focus = storageCleanup.focus
        switch (focus, direction) {
        case (.volumes, .left): selectStorageVolume(offset: -1)
        case (.volumes, .right): selectStorageVolume(offset: 1)
        case (.volumes, .down): focus = .sort
        case (.sort, .left): storageCleanup.sort = .size
        case (.sort, .right): storageCleanup.sort = .lastPlayed
        case (.sort, .up): focus = .volumes
        case (.sort, .down): focus = count > 0 ? .game(0) : .done
        case (.game(let index), .up): focus = index == 0 ? .sort : .game(index - 1)
        case (.game(let index), .down): focus = index + 1 < count ? .game(index + 1) : canDelete ? .delete : .done
        case (.done, .up), (.delete, .up): focus = count > 0 ? .game(count - 1) : .sort
        case (.done, .right): if canDelete { focus = .delete }
        case (.delete, .left): focus = .done
        default: break
        }
        storageCleanup.focus = focus
    }

    func activateStorageFocus() {
        switch storageCleanup.focus {
        case .volumes: storageCleanup.focus = .sort
        case .sort: toggleStorageSort()
        case .game(let index): if let row = storageRows[safe: index] { toggleStorageSelection(row.id) }
        case .done: panel = nil
        case .delete: if !storageSelectedRows.isEmpty { storageCleanup.confirming = true; storageCleanup.confirmIndex = 0 }
        }
    }

    /// One confirmation for the batch. Each game still gets the single uninstall's Cloud check;
    /// a game with unsynced saves is held back for its own decision instead of being discarded.
    func deleteSelectedStorageGames() {
        let targets = storageSelectedRows
        storageCleanup.confirming = false
        guard !targets.isEmpty else { return }
        if isPreview {
            for row in targets { if let index = games.firstIndex(where: { $0.id == row.id }) { games[index].status = .notInstalled } }
            storageCleanup.selection = []; reloadStorageRows(); return
        }
        guard let installQueue else { storageCleanup.message = "The install queue is unavailable."; return }
        storageCleanup.message = nil
        storageCleanupTask = Task { [weak self] in
            guard let self else { return }
            var queued: [GameID] = [], failed: [String] = []
            for (number, row) in targets.enumerated() {
                guard !Task.isCancelled, panel == .storage else { break }
                storageCleanup.progress = "Checking saves for \(row.title) · \(number + 1) of \(targets.count)"
                do {
                    guard let preparation = try await prepareUninstall(row.id, while: { self.panel == .storage }) else { break }
                    switch preparation {
                    case .ready(let authorization):
                        _ = try await installQueue.uninstall(authorization); queued.append(row.id)
                    case .needsDecision(let review, let message):
                        storageCleanup.decisions.append((row.id, review, message))
                    }
                } catch is CancellationError { break }
                catch { failed.append(row.title) }
            }
            storageCleanup.progress = nil
            storageCleanup.selection.subtract(queued + storageCleanup.decisions.map(\.id))
            guard panel == .storage else { return }
            reloadStorageRows()
            if failed.isEmpty && !Task.isCancelled {
                panel = nil
                if !queued.isEmpty { selectTab(.downloads) }
            } else {
                var lines: [String] = []
                if !queued.isEmpty { lines.append("\(queued.count) game\(queued.count == 1 ? "" : "s") queued for removal.") }
                if !failed.isEmpty { lines.append("Couldn’t prepare \(failed.joined(separator: ", ")). Their files have been kept.") }
                storageCleanup.message = lines.joined(separator: " ")
            }
        }
    }

    /// Opens the uninstall dialog, already at its unsynced choice, for the next held-back game.
    func presentNextStorageDecision() {
        guard panel == nil, !resetBusy, !storageCleanup.decisions.isEmpty else { return }
        let next = storageCleanup.decisions.removeFirst()
        uninstallInstallation = next.review.installation; uninstallReview = next.review
        uninstallPhase = .unsynced; uninstallError = next.message
        show(.uninstall(next.id))
    }
}

extension LibraryModel {
    func configureStorageSnapshot(_ screen: String) {
        selectTab(.settings); settingsSection = 1; settingsRailFocused = false; settingsIndex = 2
        controllerName = "DUALSHOCK 4"; keyboardNavigation = false
        showStorageCleanup()
        let rows = storageRows
        storageCleanup.selection = Set(rows.prefix(2).map(\.id))
        storageCleanup.focus = rows.count > 2 ? .game(2) : .done
        if screen == "settings-storage-confirm" { storageCleanup.focus = .delete; storageCleanup.confirming = true; storageCleanup.confirmIndex = 1 }
    }
}
