import Foundation
import Domain
import Sessions

extension LibraryModel {
    func configureSessionSnapshot(_ screen: String) {
        guard fixedClock, let game = games.first(where: { $0.title == "TUNIC" }) else { return }
        selectTab(.library); openGame(game)
        let record = SourceGameRecord(id: game.id, title: game.title, coverURL: game.coverURL, heroURL: game.heroURL, logoURL: game.logoURL)
        var played = PlaySessionRecord(gameID: game.id, bottleID: "snapshot-only")
        played.playedSeconds = 24 * 60
        session = .init(phase: screen == "launching" ? .launching : .running, game: record, session: played)
        exitOverlay = screen != "launching"; exitIndex = screen == "exit-overlay-quit" ? 1 : 0
        controllerName = "DUALSHOCK 4"; keyboardNavigation = false
        if screen.hasPrefix("notification") {
            session.phase = .idle; exitOverlay = false; detailID = nil
            sessionIssue = .init(stage: "Game closed unexpectedly", reason: "TUNIC closed unexpectedly. You can view the session log for details.", output: "Snapshot fixture")
            sessionIssueFocused = screen == "notification-focused"
        }
    }
}
