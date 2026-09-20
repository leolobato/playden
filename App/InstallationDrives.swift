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
            return "Reconnect this game’s drive and allow Playden access. Play will return automatically."
        }
        if isCheckingInstallationDrive(game.id) { return "Checking this game’s saved drive before playing…" }
        return nil
    }
}

extension LibraryModel {
    var enabledInstallVolumes: [GamesVolumeSelection] {
        if installVolumes.isEmpty, let gamesVolume { return [gamesVolume] }
        return installVolumes
    }

    // Keep saved, disconnected drives visible so they can still be disabled or chosen.
    var installVolumeRows: [GamesVolume] {
        availableVolumes + enabledInstallVolumes.filter { saved in
            !availableVolumes.contains { $0.id == saved.volumeID }
        }.map { saved in
            GamesVolume(id: saved.volumeID, name: volumeLabel(saved),
                        mountURL: saved.lastKnownRoot, gamesRoot: saved.lastKnownRoot, freeBytes: 0)
        }
    }

    func volumeLabel(_ selection: GamesVolumeSelection) -> String {
        availableVolumes.first { $0.id == selection.volumeID }?.name ?? selection.lastKnownRoot.path
    }

    func refreshInstallVolumes() async {
        guard !refreshingInstallVolumes, let volumeStore else { return }
        refreshingInstallVolumes = true
        defer { refreshingInstallVolumes = false }
        do { availableVolumes = try await volumeStore.availableVolumes() }
        catch { installVolumeError = error.localizedDescription }
    }

    func saveInstallVolumes(_ volumes: [GamesVolumeSelection], default selection: GamesVolumeSelection?) throws {
        try updateSetupPreferences { $0.installVolumes = volumes; $0.gamesVolume = selection }
        installVolumes = volumes; gamesVolume = selection; installVolumeError = nil
    }

    func setDefaultInstallVolume(_ selection: GamesVolumeSelection) {
        guard enabledInstallVolumes.contains(selection) else { return }
        do { try saveInstallVolumes(enabledInstallVolumes, default: selection) }
        catch { installVolumeError = error.localizedDescription }
    }

    func toggleInstallVolume(at index: Int) {
        guard !volumeSaving, let volume = installVolumeRows[safe: index] else { return }
        let enabled = enabledInstallVolumes
        if enabled.contains(where: { $0.volumeID == volume.id }) {
            let remaining = enabled.filter { $0.volumeID != volume.id }
            do {
                try saveInstallVolumes(remaining, default: gamesVolume?.volumeID == volume.id ? remaining.first : gamesVolume)
            } catch { installVolumeError = error.localizedDescription }
            return
        }
        guard let volumeStore else { return }
        volumeSaving = true
        let (generation, previous) = beginSetupOperation()
        setupTask = Task { [weak self] in
            guard let self else { return }
            defer { if setupGeneration == generation { volumeSaving = false } }
            await previous?.value
            guard setupGeneration == generation, !Task.isCancelled else { return }
            do {
                let selected = try await volumeStore.select(volume)
                guard setupGeneration == generation, !Task.isCancelled else { return }
                try saveInstallVolumes(enabledInstallVolumes + [selected], default: gamesVolume ?? selected)
            } catch { installVolumeError = error.localizedDescription }
        }
    }
}
