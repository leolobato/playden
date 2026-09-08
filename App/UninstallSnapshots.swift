import Foundation
import Domain

extension LibraryModel {
    func configureUninstallSnapshot(_ screen: String) {
        guard fixedClock, let game = games.first(where: { $0.title == "A Short Hike" }) else { return }
        selectTab(.library); openGame(game)
        controllerName = "DUALSHOCK 4"; keyboardNavigation = false
        let source = SourceGameRecord(id: game.id, title: game.title, coverURL: game.coverURL, heroURL: game.heroURL, logoURL: game.logoURL)
        let installed = InstallationRecord(game: source,
            location: .init(volumeID: "snapshot", lastKnownRoot: URL(fileURLWithPath: "/snapshot"), relativePath: "game"),
            bottleID: "snapshot", manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: 331_600_000)
        uninstallInstallation = installed
        uninstallReview = .init(installation: installed, latestSession: nil, cloudOperations: [])
        uninstallPhase = screen == "uninstall-unsynced" ? .unsynced : screen == "uninstall-checking" ? .checking : .confirm
        uninstallBusy = screen == "uninstall-checking"
        if screen == "uninstall-unsynced" {
            uninstallError = "Steam could not be reached. Retry sync to protect your latest progress before uninstalling."
            cloudStatuses[game.id] = .init(gameID: game.id, state: .pendingUpload, message: uninstallError!)
        }
        show(.uninstall(game.id)); panelIndex = uninstallBusy ? 0 : uninstallChoices(game.id).count - 1
    }
}
