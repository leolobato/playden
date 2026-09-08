import Foundation
import Domain
import Input

struct LauncherQuitRequest: Equatable {
    var sessionID: UUID?
    var gameID: GameID?
}

extension LibraryModel {
    private var currentLauncherQuitRequest: LauncherQuitRequest {
        .init(sessionID: session.session?.id, gameID: session.session?.gameID ?? session.game?.id)
    }
    var isConfirmingLauncherQuit: Bool { launcherQuitRequest != nil }

    func requestLauncherQuit() {
        guard hasActiveSession, !launcherQuitting else { return }
        launcherQuitApproval = nil
        launcherQuitRequest = currentLauncherQuitRequest
        setExitOverlay(true)
    }

    func keepLauncherOpen() {
        guard !launcherQuitting else { return }
        launcherQuitRequest = nil; launcherQuitApproval = nil
        returnToGame()
    }

    func confirmLauncherQuit() {
        guard !launcherQuitting, !sessionBusy, let request = launcherQuitRequest,
              hasActiveSession, request == currentLauncherQuitRequest else { return }
        launcherQuitApproval = request
        onLauncherQuit?()
    }

    func consumeLauncherQuitApproval() -> Bool {
        defer { launcherQuitApproval = nil }
        return hasActiveSession && launcherQuitApproval == currentLauncherQuitRequest
    }

    func reconcileLauncherQuitRequest() {
        guard let request = launcherQuitRequest,
              !hasActiveSession || request != currentLauncherQuitRequest else { return }
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
