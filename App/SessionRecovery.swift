import Foundation
import Domain

enum SessionIssueRecovery: Equatable {
    case play(GameID)
    case checkpoint(UUID)
    case recoverSession
    case downloadPolicy
    case signIn
}

extension LibraryModel {
    func reportSessionIssue(_ failure: OperationFailure, gameID: GameID? = nil, recovery: SessionIssueRecovery? = nil) {
        sessionIssue = failure
        sessionIssueGameID = gameID
        sessionIssueRecovery = recovery
    }

    var canRetrySessionIssue: Bool {
        guard sessionIssue != nil, let recovery = sessionIssueRecovery, !resetBusy else { return false }
        // Signing in again belongs to the account, not the session service, so it stays
        // offerable even when no session could ever be started.
        if recovery == .signIn { return source != nil || fixedClock }
        if case .checkpoint(let id) = recovery {
            return sessions != nil && session.session?.id == id && session.failure?.stage == "Save session" && !sessionBusy
        }
        return (sessions != nil || fixedClock) && !hasActiveSession && !sessionBusy
    }

    func retrySessionIssue() {
        guard canRetrySessionIssue, let recovery = sessionIssueRecovery else { return }
        if recovery == .signIn { beginSignIn(); return }
        guard let sessions else { return }
        panel = nil; sessionIssue = nil
        switch recovery {
        case .signIn: break // Handled above; sign-in never reaches the session service.
        case .play(let id):
            // SessionService repeats safety checks and resumes durable runtime/source preparation.
            // The captured ID belongs to the failed request, never the currently highlighted tile.
            beginPlay(id)
        case .checkpoint(let id):
            sessionBusy = true
            sessionCommand = Task { [weak self] in
                guard let self else { return }
                defer { sessionBusy = false }
                do {
                    try await sessions.retryCheckpoint(sessionID: id)
                    var updates = await sessions.updates().makeAsyncIterator()
                    if let snapshot = await updates.next() { receiveSession(snapshot) }
                } catch {
                    reportSessionIssue(sessionFailure(error, stage: "Save session"), gameID: sessionIssueGameID, recovery: recovery)
                }
            }
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
