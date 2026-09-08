import Foundation
import Domain
import Input

struct LauncherQuitRequest: Equatable {
    var sessionID: UUID?
    var gameID: GameID?
    var jobIDs: Set<UUID> = []
}

extension LibraryModel {
    private var quitWork: [JobRecord] { installJobs.filter { [.running, .queued, .stopping].contains($0.state) } }
    var requiresLauncherQuitConfirmation: Bool { hasActiveSession || !quitWork.isEmpty }
    var launcherQuitConsequences: String {
        hasActiveSession
            ? "This closes the game and Playden. Unsaved progress may be lost. Downloads pause so you can resume them later."
            : "This pauses downloads and installation work. Downloaded files are kept. File checks may restart when you reopen Playden."
    }
    var launcherQuitGame: Game? {
        if hasActiveSession { return sessionGame }
        let job = quitWork.first { $0.id == activeInstallID } ?? quitWork.first
        return games.first { $0.id == job?.gameID }
    }

    private var currentLauncherQuitRequest: LauncherQuitRequest {
        .init(sessionID: hasActiveSession ? session.session?.id : nil,
              gameID: hasActiveSession ? session.session?.gameID ?? session.game?.id : nil, jobIDs: Set(quitWork.map(\.id)))
    }
    var isConfirmingLauncherQuit: Bool { launcherQuitRequest != nil }

    func quitLauncherFromUI() {
        guard !launcherQuitting else { return }
        if requiresLauncherQuitConfirmation { requestLauncherQuit() }
        else { onLauncherQuit?() }
    }

    func requestLauncherQuit() {
        guard requiresLauncherQuitConfirmation, !launcherQuitting else { return }
        launcherQuitApproval = nil
        launcherQuitRequest = currentLauncherQuitRequest
        setExitOverlay(true)
    }

    func keepLauncherOpen() {
        guard !launcherQuitting else { return }
        launcherQuitRequest = nil; launcherQuitApproval = nil
        if hasActiveSession { returnToGame() } else { setExitOverlay(false) }
    }

    func confirmLauncherQuit() {
        guard !launcherQuitting, !sessionBusy, let request = launcherQuitRequest,
              requiresLauncherQuitConfirmation, request == currentLauncherQuitRequest else { return }
        launcherQuitApproval = request
        onLauncherQuit?()
    }

    func consumeLauncherQuitApproval() -> Bool {
        defer { launcherQuitApproval = nil }
        return requiresLauncherQuitConfirmation && launcherQuitApproval == currentLauncherQuitRequest
    }

    func reconcileLauncherQuitRequest() {
        guard let request = launcherQuitRequest,
              !requiresLauncherQuitConfirmation || request != currentLauncherQuitRequest else { return }
        launcherQuitRequest = nil; launcherQuitApproval = nil
        if !launcherQuitting { setExitOverlay(false) }
    }

    func resetLauncherQuit() {
        launcherQuitting = false; launcherQuitRequest = nil; launcherQuitApproval = nil
    }

    func performLauncherQuitInput(_ action: InputAction) -> Bool {
        if launcherQuitting { return true }
        guard isConfirmingLauncherQuit else { return false }
        switch action {
        case .move(let direction): exitIndex = direction == .up || direction == .left ? 0 : 1
        case .confirm: exitIndex == 0 ? keepLauncherOpen() : confirmLauncherQuit()
        case .back, .holdHome: keepLauncherOpen()
        default: break
        }
        return true
    }
}
