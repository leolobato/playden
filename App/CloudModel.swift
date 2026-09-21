import Foundation
import Domain
import Input

enum CloudChoice: String { case local = "Use local save", remote = "Use Cloud save", attach = "Use this Steam account", retry = "Retry sync", offline = "Play offline", close = "Close" }

extension LibraryModel {
    func refreshCloudAvailability() {
        guard !isPreview, let catalog, let source else { return }
        do {
            let entries = try catalog.snapshot().entries
            let identities = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.installation.map { (entry.id, $0.id) } })
            for (id, previous) in cloudInstallationIDs where identities[id] != previous { cloudStatuses[id] = nil }
            cloudInstallationIDs = identities
            var values: [GameID: Bool] = [:]
            var cached: [GameID: (plan: InstallPlan, available: Bool?)] = [:]
            for entry in entries {
                guard let installed = entry.installation, let plan = installed.plan else { continue }
                // Metadata updates for other games must not repeatedly inspect this plan.
                // Cache failures too; retry when the saved plan changes.
                let available: Bool?
                if let previous = cloudAvailabilityCache[entry.id], previous.plan == plan {
                    available = previous.available
                } else {
                    available = try? source.installer(for: installed.game).supportsCloudSaves(plan)
                }
                cached[entry.id] = (plan, available)
                values[entry.id] = available
            }
            cloudAvailabilityCache = cached
            cloudAvailability = values
        } catch { } // Existing status and mapped-file checks remain authoritative on failure.
    }
    func startCloudServices() {
        guard let cloudService, cloudObserver == nil else { return }
        cloudObserver = Task { [weak self] in
            var previous: [GameID: CloudSyncStatus] = [:]
            for await values in await cloudService.updates() {
                guard let self, !Task.isCancelled else { return }
                for (id, value) in values where previous[id] != value {
                    if value.state != .upToDate || self.identity != nil { self.cloudStatuses[id] = value }
                }
                previous = values
            }
        }
    }
    func stopCloudCommands() async {
        let tasks = Array(cloudCommands.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        cloudCommands.removeAll()
    }
    func cloudLabel(_ id: GameID) -> String {
        guard let state = cloudStatuses[id]?.state else { return cloudAvailability[id] == false ? "Unavailable" : "Not checked" }
        switch state {
        case .syncing: return "Syncing…"
        case .upToDate: return "Up to date"
        case .pendingUpload: return "Pending upload"
        case .conflict: return "Conflict"
        case .unavailable: return "Unavailable"
        case .failed: return "Failed"
        }
    }
    func cloudBusy(_ id: GameID) -> Bool {
        cloudCommands[id] != nil || cloudStatuses[id]?.state == .syncing || (sessionBusy && session.session?.gameID == id) ||
            (session.session?.gameID == id && [.preparing, .syncingSaves].contains(session.phase))
    }
    func showCloud(_ id: GameID) {
        cloudReview = cloudStatuses[id]?.operation
        show(.cloudSaves(id))
        panelIndex = max(0, cloudChoices(id).count - 1)
    }
    func cloudChoices(_ id: GameID) -> [CloudChoice] {
        if cloudBusy(id) { return [.close] }
        if cloudAvailability[id] == false && session.phase != .awaitingCloud { return [.close] }
        if hasActiveSession, session.session?.gameID == id, session.session?.runtime != nil { return [.close] }
        var choices: [CloudChoice] = []
        if cloudReview?.gameID == id, let plan = cloudReview?.reviewPlan, cloudStatuses[id]?.state == .conflict {
            if plan.hasConflicts || cloudReview?.needsRecoveryReview == true { choices += [.local, .remote] }
            else if plan.requiresAccountConfirmation { choices.append(.attach) }
        }
        choices.append(.retry)
        if session.phase == .awaitingCloud, session.session?.gameID == id, session.cloudStatus?.canPlayOffline == true { choices.append(.offline) }
        choices.append(.close)
        return choices
    }
    func cloudChoiceTitle(_ choice: CloudChoice, id: GameID) -> String {
        guard cloudReview?.gameID == id, cloudReview?.needsRecoveryReview == true else { return choice.rawValue }
        switch choice {
        case .local: return "Keep current files"
        case .remote: return "Restore recovered files"
        default: return choice.rawValue
        }
    }
    func cloudMessage(_ id: GameID) -> String {
        if hasActiveSession, session.session?.gameID == id, session.session?.runtime?.phase == .running {
            return "Save sync resumes when the game closes."
        }
        return cloudStatuses[id]?.message ?? (cloudAvailability[id] == false ? "Cloud save locations for this game are not supported yet. Its local saves stay on this Mac." : "Playden checks Steam Cloud before you play and syncs changes after the game closes.")
    }
    func performCloudInput(_ action: InputAction) -> Bool {
        guard case .cloudSaves(let id) = panel else { return false }
        switch action {
        case .move(let direction):
            panelIndex = min(max(0, panelIndex + (direction == .left || direction == .up ? -1 : 1)), max(0, cloudChoices(id).count - 1))
        case .confirm: if let choice = cloudChoices(id)[safe: panelIndex] { activateCloud(choice, id: id) }
        case .back: activateCloud(.close, id: id)
        default: break
        }
        return true
    }
    func activateCloud(_ choice: CloudChoice, id: GameID) {
        guard cloudChoices(id).contains(choice) else { return }
        if choice == .close {
            panel = nil
            if session.phase == .awaitingCloud, session.session?.gameID == id {
                sessionCommand = Task { [weak self] in
                    do { try await self?.sessions?.quit() }
                    catch { if let self { self.reportSessionIssue(self.sessionFailure(error, stage: "Cloud saves"), gameID: id) } }
                }
            }
            return
        }
        guard !cloudBusy(id), let cloudService else { return }
        let authorization: CloudSyncAuthorization?
        if [.local, .remote, .attach].contains(choice) {
            guard let review = cloudReview, review.gameID == id else { return }
            authorization = .init(operation: review, conflictChoice: choice == .local ? .local : choice == .remote ? .remote : nil,
                attachAccount: !review.needsLocalRecovery)
        } else { authorization = nil }
        if session.phase == .awaitingCloud, session.session?.gameID == id {
            sessionBusy = true; panel = nil
            sessionCommand = Task { [weak self] in
                guard let self else { return }
                defer { sessionBusy = false }
                do {
                    if choice == .offline { try await sessions?.playOffline() }
                    else { try await sessions?.retryCloud(authorization: authorization) }
                } catch { reportSessionIssue(sessionFailure(error, stage: "Cloud saves"), gameID: id); showCloud(id) }
            }
            return
        }
        guard let catalog, let source else { return }
        cloudCommands[id] = Task { [weak self] in
            guard let self else { return }
            defer { cloudCommands[id] = nil }
            do {
                guard let installed = try catalog.snapshot().entries.first(where: { $0.id == id })?.installation,
                      let plan = installed.plan else { throw SourceFailure.unavailable }
                let mapping = try source.installer(for: installed.game).saveMapping(plan)
                let result = await cloudService.synchronize(installed, mapping: mapping, preparingSessionID: nil, authorization: authorization)
                cloudStatuses[id] = result
                if panel == .cloudSaves(id) { cloudCommands[id] = nil; showCloud(id) }
            } catch {
                cloudStatuses[id] = .init(gameID: id, state: .unavailable, message: "This game's Cloud save mapping is unavailable. Verify its installation and retry.")
            }
        }
    }
}
