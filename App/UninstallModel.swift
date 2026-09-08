import Foundation
import Domain
import Input

enum UninstallPhase { case confirm, checking, unsynced, failed }
enum UninstallChoice: String { case cancel = "Cancel", remove = "Uninstall", retry = "Retry sync", review = "Review saves", discard = "Discard and uninstall" }

extension LibraryModel {
    func beginUninstall(_ id: GameID) {
        guard !uninstallBusy else { return }
        do {
            uninstallInstallation = try catalog?.snapshot().entries.first(where: { $0.id == id })?.installation
            guard isPreview || uninstallInstallation != nil else { throw SourceFailure.unavailable }
            uninstallPhase = .confirm; uninstallReview = nil; uninstallError = nil
            show(.uninstall(id))
        } catch { show(.information("This game's installation is unavailable. Refresh the library and try again.")) }
    }
    func uninstallChoices(_ id: GameID) -> [UninstallChoice] {
        if uninstallBusy { return [.cancel] }
        switch uninstallPhase {
        case .confirm: return [.cancel, .remove]
        case .checking: return [.cancel]
        case .failed: return [.cancel, .retry]
        case .unsynced:
            return [.cancel, .retry] + (cloudStatuses[id]?.state == .conflict ? [.review] : []) + (uninstallReview == nil ? [] : [.discard])
        }
    }
    func performUninstallInput(_ action: InputAction) -> Bool {
        guard case .uninstall(let id) = panel else { return false }
        switch action {
        case .move(let direction): panelIndex = min(max(0, panelIndex + (direction == .left || direction == .up ? -1 : 1)), uninstallChoices(id).count - 1)
        case .confirm: if let choice = uninstallChoices(id)[safe: panelIndex] { activateUninstall(choice, id: id) }
        case .back: activateUninstall(.cancel, id: id)
        default: break
        }
        return true
    }
    func activateUninstall(_ choice: UninstallChoice, id: GameID) {
        guard uninstallChoices(id).contains(choice) else { return }
        if choice == .cancel { uninstallTask?.cancel(); panel = nil; return }
        if choice == .review { showCloud(id); return }
        guard !uninstallBusy else { return }
        if isPreview {
            if let index = games.firstIndex(where: { $0.id == id }) { games[index].status = .notInstalled }
            panel = nil; detailAction = 0; return
        }
        guard let catalog, let installQueue else { uninstallPhase = .failed; uninstallError = "The install queue is unavailable."; return }
        let displayedReview = uninstallReview
        uninstallBusy = true; uninstallPhase = .checking; uninstallError = nil; panelIndex = 0
        uninstallTask = Task { [weak self] in
            guard let self else { return }
            defer { uninstallBusy = false }
            do {
                let authorization: UninstallAuthorization
                if choice == .discard {
                    guard let displayedReview else { throw SourceFailure.unavailable }
                    authorization = .init(review: displayedReview, discardUnsyncedProgress: true)
                } else {
                    if hasActiveSession, session.session?.gameID == id { try await sessions?.quit() }
                    if let command = cloudCommands[id] { await command.value }
                    try Task.checkCancellation()
                    guard panel == .uninstall(id), let installed = try catalog.snapshot().entries.first(where: { $0.id == id })?.installation else { return }
                    var synchronized = false
                    if let cloudService, let source, let plan = installed.plan {
                        do {
                            let mapping = try source.installer(for: installed.game).saveMapping(plan)
                            let result = await cloudService.synchronize(installed, mapping: mapping, preparingSessionID: nil, authorization: nil)
                            cloudStatuses[id] = result; synchronized = result.state == .upToDate
                        } catch {
                            cloudStatuses[id] = .init(gameID: id, state: .unavailable, message: "This game's Cloud save locations could not be checked. Local progress has been kept.")
                        }
                    }
                    try Task.checkCancellation()
                    guard panel == .uninstall(id) else { return }
                    let review = try catalog.reviewUninstall(id)
                    uninstallReview = review
                    if !synchronized || review.requiresDiscardConfirmation {
                        uninstallPhase = .unsynced
                        uninstallError = cloudStatuses[id]?.message ?? "This game's local saves could not be synced to Steam Cloud."
                        panelIndex = 0; return
                    }
                    authorization = .init(review: review, discardUnsyncedProgress: false)
                }
                try Task.checkCancellation()
                guard panel == .uninstall(id) else { return }
                _ = try await installQueue.uninstall(authorization)
                panel = nil; selectTab(.downloads)
                downloadIndex = downloadGames.firstIndex(where: { $0.id == id }) ?? 0
            } catch {
                guard !Task.isCancelled, panel == .uninstall(id) else { return }
                uninstallPhase = .failed; uninstallReview = nil; panelIndex = 0
                uninstallError = (error as? OperationFailure)?.reason ?? "Uninstall could not be prepared. Retry to check the latest game and save state."
            }
        }
    }
    func stopUninstallPreparation() async {
        uninstallTask?.cancel(); await uninstallTask?.value; uninstallTask = nil
    }
}
