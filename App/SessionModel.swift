import Foundation
import Domain
import Sessions
import Input

extension LibraryModel {
    var showsSessionIssue: Bool { sessionIssue != nil && !hasActiveSession && panel == nil && authScreen == nil && setupScreen == nil }
    var sessionIssueActions: [String] { (session.session?.gameID == nil ? [] : ["View logs"]) + ["Dismiss"] }
    func activateSessionIssue() {
        if sessionIssueActions[safe: sessionIssueIndex] == "View logs", let id = session.session?.gameID {
            sessionIssueFocused = false; show(.logs(id))
        } else { sessionIssue = nil }
    }
    var hasActiveSession: Bool { session.phase != .idle }
    var isLaunchingGame: Bool { session.phase == .preparing || session.phase == .launching }
    var sessionGame: Game? {
        guard let record = session.game else { return nil }
        return games.first { $0.id == record.id } ?? Game(id: record.id, title: record.title, coverURL: record.coverURL, heroURL: record.heroURL, logoURL: record.logoURL)
    }
    func startSessionServices() {
        guard let sessions, sessionObserver == nil else { return }
        sessionObserver = Task { [weak self] in
            for await snapshot in await sessions.updates() {
                guard let self, !Task.isCancelled else { return }
                self.receiveSession(snapshot)
            }
        }
        sessionStartup = Task { [weak self] in
            guard let self else { return }
            do { try await sessions.start(downloadWhilePlaying: self.downloadWhilePlaying); self.sessionReady = true }
            catch { self.sessionIssue = self.sessionFailure(error, stage: "Recover session") }
        }
    }
    func receiveSession(_ snapshot: SessionSnapshot) {
        let previous = session
        session = snapshot
        if previous.phase == .idle && snapshot.phase != .idle { onGameStarted?() }
        if let failure = snapshot.failure { sessionIssue = failure }
        if let window = snapshot.session?.runtime?.window,
           previous.session?.runtime?.hadWindow != true && snapshot.session?.runtime?.hadWindow == true && !exitOverlay {
            onGameWindow?(window)
        }
        if snapshot.phase == .idle && (previous.phase != .idle || (snapshot.session?.endedAt != nil && previous.session?.id != snapshot.session?.id)) {
            if sessionIssue?.stage == "Return to game" { sessionIssue = nil }
            setExitOverlay(false); sessionBusy = false
            reloadCatalog()
            tab = sessionOrigin
            detailID = snapshot.session?.outcome == .launchFailed || sessionOrigin != .home ? snapshot.session?.gameID : nil
            detailAction = 0; reconcileFocus()
            if snapshot.session?.outcome == .crash && sessionIssue == nil {
                sessionIssue = .init(stage: "Game closed unexpectedly", reason: "\(snapshot.game?.title ?? "The game") closed unexpectedly. View logs for details.", output: snapshot.session?.runtime?.output ?? "")
            }
            onGameEnded?()
        }
    }
    func beginPlay(_ id: GameID) {
        guard !sessionBusy else { return }
        guard let sessions else {
            show(.information(isPreview ? "Play is available in the live app." : "The game service is unavailable. Restart Big Screen to try again.")); return
        }
        guard sessionReady else {
            sessionIssue = sessionIssue ?? .init(stage: "Recover session", reason: "Finishing session recovery. Try Play again in a moment.", output: ""); return
        }
        if hasActiveSession {
            if session.session?.gameID == id { returnToGame() }
            else { show(.confirmation(.switchGame(id))) }
            return
        }
        sessionOrigin = tab; sessionIssue = nil; sessionBusy = true
        sessionCommand = Task { [weak self] in
            do { try await sessions.play(id) }
            catch { self?.sessionIssue = self?.sessionFailure(error, stage: "Launch game") }
            self?.sessionBusy = false
        }
    }
    func switchToGame(_ id: GameID) {
        guard let sessions, !sessionBusy else { return }
        let origin = tab
        panel = nil; sessionBusy = true
        sessionCommand = Task { [weak self] in
            do {
                try await sessions.quit()
                guard let self else { return }
                var updates = await sessions.updates().makeAsyncIterator()
                if let snapshot = await updates.next() { self.receiveSession(snapshot) }
                self.sessionBusy = false; self.sessionOrigin = origin; self.tab = origin
                self.beginPlay(id)
            } catch { self?.sessionBusy = false; self?.sessionIssue = self?.sessionFailure(error, stage: "Quit game") }
        }
    }
    func setExitOverlay(_ visible: Bool) {
        exitOverlay = visible
        if visible { exitIndex = 0 }
        onExitOverlayChanged?(visible)
    }
    func returnToGame() {
        guard hasActiveSession else { return }
        setExitOverlay(false)
        if let window = session.session?.runtime?.window { onGameWindow?(window) }
    }
    func quitGame() {
        guard let sessions, !sessionBusy else { return }
        sessionBusy = true; sessionIssue = nil
        sessionCommand = Task { [weak self] in
            do { try await sessions.quit() }
            catch { self?.sessionIssue = self?.sessionFailure(error, stage: "Quit game") }
            self?.sessionBusy = false
        }
    }
    func performSessionInput(_ action: InputAction) -> Bool {
        if case .holdHome = action {
            if hasActiveSession { exitOverlay ? returnToGame() : setExitOverlay(true) }
            return true
        }
        if exitOverlay {
            guard !sessionBusy else { return true }
            switch action {
            case .move(let direction): exitIndex = direction == .up || direction == .left ? 0 : 1
            case .confirm: exitIndex == 0 ? returnToGame() : quitGame()
            case .back: returnToGame()
            default: break
            }
            return true
        }
        if isLaunchingGame {
            if case .back = action { setExitOverlay(true) }
            return true
        }
        if showsSessionIssue {
            if case .context = action { sessionIssueFocused.toggle(); sessionIssueIndex = 0; return true }
            if sessionIssueFocused {
                switch action {
                case .move(let direction): sessionIssueIndex = min(max(0, sessionIssueIndex + (direction == .left || direction == .up ? -1 : 1)), sessionIssueActions.count - 1)
                case .confirm: activateSessionIssue()
                case .back: sessionIssueFocused = false
                default: sessionIssueFocused = false; return false
                }
                return true
            }
        } else { sessionIssueFocused = false }
        return false
    }
    func updateSessionDownloadPolicy() {
        guard !restoringState, let sessions, sessionReady else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await sessions.setDownloadWhilePlaying(self.downloadWhilePlaying) }
            catch { self.sessionIssue = self.sessionFailure(error, stage: "Pause downloads") }
        }
    }
    func sessionFailure(_ error: Error, stage: String) -> OperationFailure {
        error as? OperationFailure ?? .init(stage: stage, reason: error.localizedDescription, output: error.localizedDescription)
    }
}
