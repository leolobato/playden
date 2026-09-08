import Foundation
import Domain
import Sessions

extension LibraryModel {
    func configureGameStatusSnapshot(_ screen: String) {
        guard fixedClock, let index = games.firstIndex(where: { $0.title == "A Short Hike" }) else { return }
        games[index].status = .installed; games[index].compatibility = .works
        games[index].lastSessionOutcome = screen == "game-status-crash" ? .crash : .clean
        games[index].lastPlayedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let game = games[index]
        controllerName = "DUALSHOCK 4"; keyboardNavigation = false
        selectTab(.library)
        if screen == "library-running" {
            for title in ["Cuphead", "Hades"] {
                if let other = games.firstIndex(where: { $0.title == title }) {
                    games[other].compatibility = title == "Cuphead" ? .playable : .broken
                }
            }
            libraryCursor = .init(index: filteredGames.firstIndex { $0.id == game.id } ?? 0)
            session = .init(phase: .running, game: .init(id: game.id, title: game.title),
                            session: .init(gameID: game.id, bottleID: "snapshot-only"))
        } else {
            openGame(game)
            if screen == "context-uninstall" {
                show(.context); panelIndex = contextActions.firstIndex(of: "Uninstall") ?? 0
            } else {
                compatibilityNotes[game.id] = "Works well with a controller. " + String(repeating: "Use the in-game resolution setting for your TV. ", count: 6)
            }
        }
    }
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
            reportSessionIssue(.init(stage: "Game closed unexpectedly", reason: "TUNIC closed unexpectedly. Retry or view the session log for details.", output: "Snapshot fixture"), gameID: game.id, recovery: .play(game.id))
            sessionIssueFocused = screen == "notification-focused"
        }
    }
}
