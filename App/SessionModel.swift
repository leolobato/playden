import Foundation
import Domain
import Sessions
import Input

extension LibraryModel {
    var showsSessionIssue: Bool { sessionIssue != nil && !hasActiveSession && panel == nil && authScreen == nil && setupScreen == nil }
    var sessionIssueActions: [String] {
        (canRetrySessionIssue ? ["Retry"] : []) + (sessionIssueGameID == nil ? [] : ["View logs"]) + ["Dismiss"]
    }
    func activateSessionIssue() {
        if sessionIssueActions[safe: sessionIssueIndex] == "Retry" { retrySessionIssue() }
        else if sessionIssueActions[safe: sessionIssueIndex] == "View logs", let id = sessionIssueGameID {
            sessionIssueFocused = false; show(.logs(id))
        } else { sessionIssue = nil }
    }
    var canShowGameControls: Bool { [.preparing, .launching, .running, .stopping].contains(session.phase) }
    func showGameControls() {
        guard canShowGameControls else { return }
        panel = nil
        setExitOverlay(true)
    }
    var hasActiveSession: Bool { session.phase != .idle }
    func isGameRunning(_ id: GameID) -> Bool {
        session.session?.gameID == id && (session.phase == .running || session.phase == .stopping)
    }
    var isLaunchingGame: Bool { session.phase == .preparing || session.phase == .launching || session.phase == .syncingSaves }
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
            catch { self.reportSessionIssue(self.sessionFailure(error, stage: "Recover session"), recovery: .recoverSession) }
        }
    }
    func receiveSession(_ snapshot: SessionSnapshot) {
        let previous = session
        session = snapshot
        reconcileLauncherQuitRequest()
        if previous.session?.id != snapshot.session?.id || snapshot.phase == .idle { gameWindowHandedOff = false }
        if let status = snapshot.cloudStatus { cloudStatuses[status.gameID] = status }
        if snapshot.phase == .awaitingCloud, let id = snapshot.session?.gameID {
            setExitOverlay(false)
            detailID = id; showCloud(id)
        }
        if snapshot.phase == .syncingSaves, previous.phase != .syncingSaves {
            setExitOverlay(false); onGameEnded?()
        }
        if previous.phase == .idle && snapshot.phase != .idle { onGameStarted?() }
        if let failure = snapshot.failure {
            let retryable = snapshot.phase == .idle && [.launchFailed, .crash].contains(snapshot.session?.outcome)
            reportSessionIssue(failure, gameID: snapshot.session?.gameID,
                               recovery: retryable ? snapshot.session.map { .play($0.gameID) } : nil)
        }
        if let window = snapshot.session?.runtime?.window,
           previous.session?.runtime?.window != window && snapshot.session?.runtime?.hadWindow == true &&
           !gameWindowHandedOff && !exitOverlay && [.launching, .running].contains(snapshot.phase) {
            onGameWindow?(window)
        }
        if snapshot.phase == .idle && (previous.phase != .idle || (snapshot.session?.endedAt != nil && previous.session?.id != snapshot.session?.id)) {
            if sessionIssue?.stage == "Return to game" { sessionIssue = nil }
            setExitOverlay(false); sessionBusy = false
            reloadCatalog()
            let launchFailed = snapshot.session?.outcome == .launchFailed
            tab = launchFailed ? sessionOrigin : .home
            detailID = launchFailed ? snapshot.session?.gameID : nil
            tabsFocused = false; detailAction = 0
            if !launchFailed {
                homeRow = 0; homeColumns[0] = 0
                if let id = snapshot.session?.gameID,
                   let row = rows.firstIndex(where: { $0.games.contains { $0.id == id } }),
                   let column = rows[row].games.firstIndex(where: { $0.id == id }) {
                    homeRow = row; homeColumns[row] = column
                }
            }
            reconcileFocus()
            if snapshot.session?.outcome == .crash && sessionIssue == nil {
                reportSessionIssue(.init(stage: "Game closed unexpectedly", reason: "\(snapshot.game?.title ?? "The game") closed unexpectedly. Retry or view logs for details.", output: snapshot.session?.runtime?.output ?? ""),
                                   gameID: snapshot.session?.gameID, recovery: snapshot.session.map { .play($0.gameID) })
            }
            if previous.phase != .syncingSaves { onGameEnded?() }
            if !uninstallBusy, snapshot.cloudStatus?.state == .conflict, let id = snapshot.session?.gameID { detailID = id; showCloud(id) }
        }
    }
    func recordGameWindowHandoff(_ window: GameWindow) {
        guard hasActiveSession, session.session?.runtime?.window == window else { return }
        gameWindowHandedOff = true
        if sessionIssue?.stage == "Return to game" { sessionIssue = nil }
    }
    func beginPlay(_ id: GameID) {
        guard !resetBusy, !launcherQuitting else { return }
        guard !sessionBusy else { return }
        if (!hasActiveSession || session.session?.gameID != id), installationDriveBlocked(id) {
            if let game = games.first(where: { $0.id == id }) { openGame(game) }
            return
        }
        guard let sessions else {
            show(.information(isPreview ? "Play is available in the live app." : "The game service is unavailable. Restart Playden to try again.")); return
        }
        guard sessionReady else {
            sessionIssue = sessionIssue ?? .init(stage: "Recover session", reason: "Finishing session recovery. Try Play again in a moment.", output: ""); return
        }
        if hasActiveSession {
            if session.phase == .awaitingCloud, session.session?.gameID == id { showCloud(id) }
            else if session.session?.gameID == id { returnToGame() }
            else { show(.confirmation(.switchGame(id))) }
            return
        }
        panel = nil
        sessionOrigin = tab; sessionIssue = nil; sessionBusy = true
        sessionCommand = Task { [weak self] in
            do {
                try await self?.immersiveDisplay.waitUntilReady()
                try await sessions.play(id)
            }
            catch { if let self { self.reportSessionIssue(self.sessionFailure(error, stage: "Launch game"), gameID: id, recovery: .play(id)) } }
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
            } catch {
                if let self {
                    self.sessionBusy = false
                    self.reportSessionIssue(self.sessionFailure(error, stage: "Quit game"), gameID: self.session.session?.gameID)
                }
            }
        }
    }
    func setExitOverlay(_ visible: Bool) {
        exitOverlay = visible
        if visible { exitIndex = 0 }
        onExitOverlayChanged?(visible)
    }
    func returnToGame() {
        guard hasActiveSession else { return }
        if !launcherQuitting { launcherQuitRequest = nil; launcherQuitApproval = nil }
        setExitOverlay(false)
        if let window = session.session?.runtime?.window { onGameWindow?(window) }
    }
    func quitGame() {
        guard let sessions, !sessionBusy else { return }
        sessionBusy = true; sessionIssue = nil
        sessionCommand = Task { [weak self] in
            do { try await sessions.quit() }
            catch { if let self { self.reportSessionIssue(self.sessionFailure(error, stage: "Quit game"), gameID: self.session.session?.gameID) } }
            self?.sessionBusy = false
        }
    }
    func performSessionInput(_ action: InputAction) -> Bool {
        if performLauncherQuitInput(action) { return true }
        if session.phase == .syncingSaves {
            switch action {
            case .back, .holdHome: if let id = session.session?.gameID { showCloud(id) }
            default: break
            }
            return true
        }
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
            catch { self.reportSessionIssue(self.sessionFailure(error, stage: "Pause downloads"), recovery: .downloadPolicy) }
        }
    }
    func sessionFailure(_ error: Error, stage: String) -> OperationFailure {
        error as? OperationFailure ?? .init(stage: stage, reason: error.localizedDescription, output: error.localizedDescription)
    }
}
