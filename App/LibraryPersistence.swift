import Foundation
import Domain
import Catalog

extension LibraryModel {
    /// Preview fixtures seed their own database once. Production callers pass preview: false and
    /// populate this same catalog through GameSource; no fixture can become a real installation.
    func restoreCatalog() {
        preservingHomeFocus { restoreCatalogContents() }
    }
    private func restoreCatalogContents() {
        guard let catalog else { return }
        do {
            if isPreview, try catalog.lastSync(for: "steam") == nil {
                let records = PreviewCatalog.games.map { game in
                    SourceGameRecord(id: game.id, title: game.title, summary: game.summary, genres: game.genres,
                        controllerSupport: .full, coverURL: game.coverURL, heroURL: game.heroURL, logoURL: game.logoURL,
                        importedPlaytimeSeconds: Int64(game.hoursPlayed) * 3600, metadataUpdatedAt: .now)
                }
                try catalog.replaceSourceCatalog(source: "steam", games: records)
                try catalog.saveLibraryState(edits: Dictionary(uniqueKeysWithValues: games.map { ($0.id, edits(for: $0)) }),
                    collections: collections, preferences: try catalog.preferences())
            }
            let snapshot = try catalog.snapshot()
            gameLaunchOptions = Dictionary(uniqueKeysWithValues: snapshot.entries.compactMap { entry in
                guard let installed = entry.installation, let plan = installed.plan else { return nil }
                if let options = plan.launchOptions { return (entry.id, options) }
                // Older installs retain Steam metadata, so choices can be recovered offline.
                guard let source, let options = try? source.installer(for: installed.game).launchOptions(plan) else { return nil }
                return (entry.id, options)
            })
            runtimeProfiles = Dictionary(uniqueKeysWithValues: snapshot.entries.compactMap { entry in
                entry.edits.runtime.map { (entry.id, $0) }
            })
            updateInstallationDriveTargets(snapshot.entries.compactMap(\.installation))
            gamesNeedingRepair = Set(snapshot.entries.filter { $0.installation?.needsRepair == true }.map(\.id))
            let fixtures = Dictionary(uniqueKeysWithValues: PreviewCatalog.games.map { ($0.id, $0) })
            games = snapshot.entries.map { entry in
                let record = entry.source
                return Game(id: record.id, title: record.title,
                    status: isPreview ? fixtures[record.id]?.status ?? .notInstalled : entry.installation == nil ? .notInstalled : .installed,
                    compatibility: entry.edits.compatibility, hoursPlayed: Int(entry.totalPlaytimeSeconds / 3600),
                    size: isPreview ? fixtures[record.id]?.size ?? "—" : entry.installation.map { ByteCountFormatter.string(fromByteCount: $0.installedBytes, countStyle: .file) } ?? record.downloadBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—",
                    summary: record.summary, genres: record.genres, coverURL: record.coverURL, heroURL: record.heroURL,
                    logoURL: record.logoURL, isFavorite: entry.edits.isFavorite, isHidden: entry.edits.isHidden,
                    lastPlayedAt: entry.lastPlayedAt, addedAt: record.sourceAcquiredAt, installedAt: entry.installation?.installedAt,
                    controllerSupport: record.controllerSupport, lastSessionOutcome: entry.lastSession?.outcome)
            }
            collections = snapshot.collections
            compatibilityNotes = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0.edits.note) })
            let preferences = snapshot.preferences
            filter = preferences.scope
            if !libraryFilters.contains(filter) { filter = .all }
            sort = preferences.sort; refinements = preferences.refinements ?? LibraryRefinements()
            reducedMotion = preferences.reducedMotion; downloadWhilePlaying = preferences.downloadWhilePlaying
            installVolumes = preferences.installVolumes ?? preferences.gamesVolume.map { [$0] } ?? []
            gamesVolume = preferences.gamesVolume; selectedDisplayID = preferences.selectedDisplayID
            selectedDisplayUUID = preferences.selectedDisplayUUID; selectedDisplayName = preferences.selectedDisplayName
            selectedAudioDeviceUID = preferences.selectedAudioDeviceUID; selectedAudioDeviceName = preferences.selectedAudioDeviceName
            startInFullscreen = preferences.startInFullscreen ?? true
            useNintendoButtonLayout = preferences.useNintendoButtonLayout ?? false
            let wasImmersive = immersiveMode
            immersiveMode = preferences.immersiveMode ?? false
            if wasImmersive != immersiveMode { onImmersiveModeChanged?() }
            applyInstallStatuses()
            reconcileFocus()
        } catch { recordPersistenceError(error) }
    }
    private func edits(for game: Game) -> GameEdits {
        var value = GameEdits(isFavorite: game.isFavorite, isHidden: game.isHidden, compatibility: game.compatibility, note: compatibilityNotes[game.id] ?? "")
        value.runtime = runtimeProfiles[game.id]
        return value
    }
    private var preferences: LibraryPreferences {
        var value = LibraryPreferences()
        value.scope = filter; value.sort = sort; value.refinements = refinements
        value.reducedMotion = reducedMotion; value.downloadWhilePlaying = downloadWhilePlaying
        return value
    }
    func persistGameEdits(previous: [Game]) {
        guard !restoringState, let catalog else { return }
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        do {
            for game in games {
                let value = edits(for: game)
                if old[game.id].map({ edits(for: $0) }) != value { try catalog.saveEdits(value, for: game.id) }
            }
        } catch { recordPersistenceError(error) }
    }
    func persistNotes(previous: [GameID: String]) {
        guard !restoringState, let catalog else { return }
        do {
            for game in games where previous[game.id] != compatibilityNotes[game.id] { try catalog.saveEdits(edits(for: game), for: game.id) }
        } catch { recordPersistenceError(error) }
    }
    func persistCollections() {
        guard !restoringState, let catalog else { return }
        do { try catalog.saveCollections(collections) } catch { recordPersistenceError(error) }
    }
    func persistPreferences() {
        guard !restoringState, let catalog else { return }
        do {
            // Preserve setup/display fields owned by their corresponding settings flows.
            var saved = try catalog.preferences()
            saved.scope = filter; saved.sort = preferences.sort; saved.refinements = refinements
            saved.reducedMotion = reducedMotion; saved.downloadWhilePlaying = downloadWhilePlaying
            try catalog.savePreferences(saved)
        } catch { recordPersistenceError(error) }
    }
    func retryPersistence() {
        guard let catalog else { return }
        do {
            var saved = try catalog.preferences()
            saved.scope = filter; saved.sort = preferences.sort; saved.refinements = refinements
            saved.reducedMotion = reducedMotion; saved.downloadWhilePlaying = downloadWhilePlaying
            try catalog.saveLibraryState(edits: Dictionary(uniqueKeysWithValues: games.map { ($0.id, edits(for: $0)) }), collections: collections, preferences: saved)
            persistenceError = nil; panel = nil
        } catch { recordPersistenceError(error) }
    }
    private func recordPersistenceError(_ error: Error) {
        persistenceError = error.localizedDescription
        show(.persistenceFailure)
    }
}
