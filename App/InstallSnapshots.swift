import Foundation
import Domain
import Installs

/// Used only by the explicit screenshot command. No catalog, source, queue or runtime is opened.
@MainActor enum InstallSnapshots {
    static func model(for screen: String) -> LibraryModel {
        let model = LibraryModel(preview: false)
        model.fixedClock = true; model.reducedMotion = true
        model.games = PreviewCatalog.games
        for index in model.games.indices { model.games[index].status = .notInstalled }
        let game = model.games.first { $0.title == "TUNIC" }!
        let source = SourceGameRecord(id: game.id, title: game.title, coverURL: game.coverURL, heroURL: game.heroURL, logoURL: game.logoURL)
        let plan = InstallPlan(game: source, manifestIDs: [:], estimate: .init(downloadBytes: 2_100_000_000, installedBytes: 3_500_000_000, requiredBytes: 7_300_000_000), launchSpec: .init(executableRelativePath: "TUNIC.exe"), sourcePayload: Data())
        let volume = GamesVolumeSelection(volumeID: "screenshot-only", rootBookmark: Data(), lastKnownRoot: URL(fileURLWithPath: "/Volumes/Games/Big Screen"), relativeRoot: "Big Screen")
        model.gamesVolume = volume
        model.gamesStorage = .init(volumeID: volume.volumeID, name: "Games", root: volume.lastKnownRoot,
            totalBytes: 2_000_000_000_000, freeBytes: screen == "install-storage-shortage" ? 9_000_000_000 : 1_350_000_000_000,
            gamesBytes: 640_000_000_000, reservedBytes: 13_900_000_000)
        if screen == "install-storage-unavailable" {
            model.gamesStorage = nil; model.gamesStorageError = "Reconnect your games drive. Storage will update automatically."
        }
        if let index = model.games.firstIndex(where: { $0.id == game.id }) { model.games[index].size = "2.1 GB" }
        if screen.hasPrefix("install-offer") {
            model.openGame(game)
            model.show(.installOffer(game.id))
            model.installOffer = .init(plan: plan, volume: volume, freeBytes: screen.hasSuffix("space") ? 5_000_000_000 : 206_000_000_000, reservedBytes: 1_000_000_000)
            model.panelIndex = 1
        } else {
            var active = JobRecord(gameID: game.id); active.plan = plan; active.state = .running; active.stage = .download
            active.bytesCompleted = 1_505_000_000; active.bytesTotal = plan.estimate.installedBytes
            active.currentFile = "TUNIC_Data/sharedassets0.assets"
            var jobs = [active]
            for (title, state) in [("Celeste", JobState.queued), ("Hades", .paused), ("Cuphead", .failed)] {
                guard let queuedGame = model.games.first(where: { $0.title == title }) else { continue }
                var job = JobRecord(gameID: queuedGame.id, queuePosition: jobs.count)
                job.state = state; job.stage = state == .failed ? .stage : .download
                if state == .paused { job.pauseReasons = [.user] }
                if state == .failed { job.failure = .init(stage: "Prepare game", reason: "Game preparation could not finish. Retry the installation.", output: "Screenshot fixture") }
                jobs.append(job)
            }
            model.installJobs = jobs; model.activeInstallID = active.id; model.installTransfer = .init(bytesPerSecond: 38_000_000, secondsRemaining: 134); model.applyInstallStatuses()
            if screen == "install-verifying" {
                model.installTransfer = .init(bytesPerSecond: 0, secondsRemaining: nil,
                    verification: .init(file: active.currentFile!, bytesChecked: 900_000_000, bytesTotal: 1_500_000_000))
            }
            if screen == "install-game-progress" { model.openGame(model.games.first { $0.id == game.id }!) }
            else if screen == "install-mini-progress" { model.selectTab(.library) }
            else { model.selectTab(.downloads) }
            if screen == "install-history-failed", let failed = jobs.first(where: { $0.state == .failed }) {
                model.downloadIndex = model.downloadGames.firstIndex { $0.id == failed.gameID } ?? 0
                model.show(.downloadActions(failed.gameID)); model.panelIndex = model.panelActions.count - 1
            }
            if screen == "install-history-completed" {
                model.installJobs[0].state = .completed; model.installJobs[0].stage = .finished; model.activeInstallID = nil
                model.downloadIndex = model.downloadGames.firstIndex { $0.id == active.gameID } ?? 0
                model.show(.downloadActions(active.gameID)); model.panelIndex = model.panelActions.count - 1
            }
        }
        return model
    }
}
