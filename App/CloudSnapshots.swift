import Foundation
import Domain

extension LibraryModel {
    func configureCloudSnapshot(_ screen: String) {
        guard fixedClock, let game = games.first(where: { $0.title == "A Short Hike" }) else { return }
        selectTab(.library); openGame(game)
        controllerName = "DUALSHOCK 4"; keyboardNavigation = false
        let source = SourceGameRecord(id: game.id, title: game.title, coverURL: game.coverURL, heroURL: game.heroURL, logoURL: game.logoURL)
        let installed = InstallationRecord(game: source, location: .init(volumeID: "snapshot", lastKnownRoot: URL(fileURLWithPath: "/snapshot"), relativePath: "game"),
            bottleID: "snapshot-only", manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: 1)
        let local = CloudLocalFile(location: .init(root: .game, path: "save.mountain"), sha1: Data(repeating: 1, count: 20), bytes: 29454, modifiedAt: Date(timeIntervalSince1970: 1788808800))
        let remote = CloudFile(name: "save.mountain", sha1: Data(repeating: 2, count: 20), bytes: 26420, modifiedAt: local.modifiedAt.addingTimeInterval(-86400))
        var operation = CloudSyncOperation(installation: installed, accountKey: "snapshot", mapping: .init())
        operation.claim = nil; operation.phase = .conflict; operation.localSnapshotID = UUID(); operation.remoteSnapshotID = UUID()
        operation.remote = .init(gameID: game.id, accountKey: "snapshot", revision: 1, files: [remote])
        operation.plan = .init(gameID: game.id, installationID: installed.id, accountKey: "snapshot", remoteRevision: 1,
            decisions: [.init(name: remote.name, location: local.location, action: .conflict, local: local, remote: remote)], requiresAccountConfirmation: screen == "cloud-account")
        if screen == "cloud-recovery", let plan = operation.plan {
            operation.needsLocalRecovery = true
            operation.localRecoveries = [.init(localSnapshotID: UUID(), remoteSnapshotID: UUID(), plan: plan)]
        }
        let state: CloudSyncStatus.State = screen == "cloud-pending" ? .pendingUpload : screen == "cloud-ready" ? .upToDate : screen == "cloud-syncing" ? .syncing : .conflict
        let status = CloudSyncStatus(gameID: game.id, state: state, operation: state == .conflict ? operation : nil,
            message: screen == "cloud-recovery" ? "Saved progress changed during an interrupted sync. Choose the files to keep on this Mac, then Playden will check Steam Cloud. Both copies are backed up." :
                state == .conflict ? "Local and Cloud progress differ. Choose which copy to use." : state == .pendingUpload ? "Steam could not be reached. Your latest progress is backed up on this Mac. Retry or play offline." : state == .syncing ? "Checking saved progress…" : "Saved progress is up to date.", canPlayOffline: screen != "cloud-recovery", latestCloudSaveAt: state == .upToDate ? local.modifiedAt : remote.modifiedAt)
        cloudStatuses = [game.id: status]
        if screen == "cloud-ready" { return }
        if screen == "cloud-syncing" { session = .init(phase: .syncingSaves, game: source, session: .init(gameID: game.id, bottleID: "snapshot-only"), cloudStatus: status); return }
        session = .init(phase: .awaitingCloud, game: source, session: .init(gameID: game.id, bottleID: "snapshot-only"), cloudStatus: status)
        showCloud(game.id)
        panelIndex = screen == "cloud-conflict" ? 1 : 0
    }
}
