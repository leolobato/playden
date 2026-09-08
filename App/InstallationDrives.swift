import Foundation
import Domain

struct InstallationDriveTarget: Equatable {
    var installationID: UUID
    var location: GameLocation
}

extension LibraryModel {
    func updateInstallationDriveTargets(_ installations: [InstallationRecord]) {
        guard !isPreview, volumeStore != nil else { return }
        let targets = Dictionary(uniqueKeysWithValues: installations.map {
            ($0.gameID, InstallationDriveTarget(installationID: $0.id, location: $0.location))
        })
        guard targets != installationDriveTargets else { return }
        installationDriveAvailable = installationDriveAvailable.filter {
            targets[$0.key] != nil && targets[$0.key] == installationDriveTargets[$0.key]
        }
        installationDriveTargets = targets
        requestInstallationDriveRefresh()
    }

    func requestInstallationDriveRefresh() {
        guard !isPreview, volumeStore != nil else { return }
        installationDriveTask?.cancel()
        checkingInstallationDrives = Set(installationDriveTargets.keys)
        installationDriveTask = Task { [weak self] in await self?.refreshInstallationDrives() }
    }

    func refreshInstallationDrives() async {
        guard !isPreview, let volumeStore else { return }
        let generation = UUID(); installationDriveGeneration = generation
        let targets = installationDriveTargets
        checkingInstallationDrives = Set(targets.keys)
        var available: [GameID: Bool] = [:]
        // Many games share a root. Check each saved selection once, without looking at the
        // currently selected download drive or trusting its last-known mount path.
        var checked: [(GamesVolumeSelection, Bool)] = []
        for (id, target) in targets {
            guard !Task.isCancelled else { return }
            let location = target.location
            guard let bookmark = location.rootBookmark, let relativeRoot = location.relativeRoot else {
                available[id] = false; continue
            }
            let selection = GamesVolumeSelection(volumeID: location.volumeID, rootBookmark: bookmark,
                lastKnownRoot: location.lastKnownRoot, relativeRoot: relativeRoot)
            if let result = checked.first(where: { $0.0 == selection }) { available[id] = result.1; continue }
            let resolved: Bool
            do { _ = try await volumeStore.resolve(selection); resolved = true }
            catch { resolved = false }
            checked.append((selection, resolved)); available[id] = resolved
        }
        guard !Task.isCancelled, installationDriveGeneration == generation,
              targets == installationDriveTargets else { return }
        installationDriveAvailable = available
        checkingInstallationDrives = []
        applyInstallationDriveStatuses()
    }

    func applyInstallationDriveStatuses() {
        guard !isPreview, !installationDriveTargets.isEmpty else { return }
        let activeJobs = Set(latestInstallJobs.filter { ![.completed, .cancelled].contains($0.state) }.map(\.gameID))
        preservingHomeFocus {
            var updated = games
            for index in games.indices {
                let id = games[index].id
                guard installationDriveTargets[id] != nil else { continue }
                // Queue and removal actions remain available even when their drive is absent.
                if activeJobs.contains(id) { continue }
                let status: InstallStatus = installationDriveAvailable[id] == false ? .driveDisconnected : .installed
                updated[index].status = status
            }
            if updated != games { games = updated }
        }
    }

    func isCheckingInstallationDrive(_ id: GameID) -> Bool {
        installationDriveTargets[id] != nil && (checkingInstallationDrives.contains(id) || installationDriveAvailable[id] == nil)
    }
    func installationDriveBlocked(_ id: GameID) -> Bool {
        installationDriveAvailable[id] == false || games.first(where: { $0.id == id })?.status == .driveDisconnected || isCheckingInstallationDrive(id)
    }
    func detailActionEnabled(at index: Int) -> Bool {
        guard let title = detailActions[safe: index] else { return false }
        return title != "Drive disconnected" && title != "Checking drive…"
    }
    func panelActionEnabled(at index: Int) -> Bool {
        panel != .context || index != 0 || detailActionEnabled(at: 0)
    }
    var installationDriveMessage: String? {
        guard let game = focusedGame else { return nil }
        if game.status == .driveDisconnected {
            return "Reconnect this game’s drive and allow Big Screen access. Play will return automatically."
        }
        if isCheckingInstallationDrive(game.id) { return "Checking this game’s saved drive before playing…" }
        return nil
    }
}
