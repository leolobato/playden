import Foundation
import Domain

enum SessionIssueRecovery: Equatable {
    case play(GameID)
    case recoverSession
    case downloadPolicy
}

extension LibraryModel {
    func reportSessionIssue(_ failure: OperationFailure, gameID: GameID? = nil, recovery: SessionIssueRecovery? = nil) {
        sessionIssue = failure
        sessionIssueGameID = gameID
        sessionIssueRecovery = recovery
    }

    var canRetrySessionIssue: Bool {
        sessionIssue != nil && sessionIssueRecovery != nil && (sessions != nil || fixedClock) &&
        !hasActiveSession && !sessionBusy && !resetBusy
    }

    func retrySessionIssue() {
        guard canRetrySessionIssue, let recovery = sessionIssueRecovery, let sessions else { return }
        panel = nil; sessionIssue = nil
        switch recovery {
        case .play(let id):
            // SessionService repeats safety checks and resumes durable runtime/source preparation.
            // The captured ID belongs to the failed request, never the currently highlighted tile.
            beginPlay(id)
        case .recoverSession, .downloadPolicy:
            sessionBusy = true
            sessionCommand = Task { [weak self] in
                guard let self else { return }
                defer { sessionBusy = false }
                do {
                    if recovery == .recoverSession {
                        await sessionStartup?.value
                        try await sessions.start(downloadWhilePlaying: downloadWhilePlaying)
                        sessionReady = true
                    } else { try await sessions.setDownloadWhilePlaying(downloadWhilePlaying) }
                } catch {
                    reportSessionIssue(sessionFailure(error, stage: recovery == .recoverSession ? "Recover session" : "Pause downloads"), recovery: recovery)
                }
            }
        }
    }
}
