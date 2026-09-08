import AppKit
import Domain
import Input

struct LogScrollRequest: Equatable {
    var sequence = 0
    var points = 0.0
}

enum LogRecovery: Equatable {
    case session(UUID, GameID)
    case job(UUID, GameID, cancellation: Bool)
    var title: String {
        if case .job(_, _, cancellation: true) = self { return "Retry cancellation" }
        return "Retry"
    }
}

extension LibraryModel {
    var logRecovery: LogRecovery? {
        guard let logDocument, !resetBusy else { return nil }
        if logDocument.kind == "play session", let logSession, logDocument.id == logSession.id,
           logDocument.gameID == logSession.gameID, logSession.endedAt != nil,
           [.launchFailed, .crash].contains(logSession.outcome),
           !hasActiveSession, !sessionBusy, (sessionReady && sessions != nil || fixedClock) {
            return .session(logDocument.id, logDocument.gameID)
        }
        if installQueue != nil, let job = liveJob(for: logDocument.gameID), job.id == logDocument.id {
            if job.cancellationRequested == true, [.paused, .failed].contains(job.state) {
                return .job(job.id, job.gameID, cancellation: true)
            }
            if job.state == .failed { return .job(job.id, job.gameID, cancellation: false) }
        }
        return nil
    }
    var logActions: [String] {
        ["Close"] + (logRecovery.map { [$0.title] } ?? []) +
        (logDocument != nil && diagnosticArchive != nil ? ["Reveal in Finder"] : [])
    }
    func activateLogAction() {
        switch logActions[safe: logActionIndex] {
        case "Close": panel = nil
        case "Reveal in Finder": revealLogFile()
        case "Retry", "Retry cancellation":
            guard let recovery = logRecovery else { return }
            switch recovery {
            case .session(let id, let gameID):
                // A newer session may have arrived since the log's last refresh.
                guard let catalog, let latest = try? catalog.latestSession(for: gameID), latest.id == id,
                      latest.endedAt != nil, [.launchFailed, .crash].contains(latest.outcome) else { return }
                panel = nil; beginPlay(gameID)
            case .job(let id, let gameID, _):
                performLiveDownloadAction(recovery.title, id: gameID, expectedJobID: id)
            }
        default: logActionIndex = 0
        }
    }
    func flushLogs() async {
        guard let catalog, let diagnosticArchive else { return }
        do { try await diagnosticArchive.synchronize(catalog) }
        catch { logArchiveError = "Logs could not be written. They will be recovered from the database on the next launch." }
    }
    func startLogServices() {
        guard !isPreview, let catalog, let diagnosticArchive, logObserver == nil else { return }
        logObserver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await diagnosticArchive.synchronize(catalog)
                    guard let self else { return }
                    self.logArchiveError = nil
                } catch { self?.logArchiveError = (error as? OperationFailure)?.reason ?? "Logs could not be written. Try again." }
                if case .logs(let id) = self?.panel { self?.refreshLogView(id) }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func refreshLogView(_ id: GameID) {
        guard let catalog else { return }
        do {
            logDocument = try catalog.diagnosticLogs(for: id).first
            logSession = try catalog.latestSession(for: id)
        }
        catch { logArchiveError = "The saved log could not be read. Try again." }
    }
    func prepareLogView(_ id: GameID) {
        logDocument = nil; logSession = nil; logScrollRequest = .init(); logScrollFraction = 0; logCanScroll = false; logActionIndex = 0
        refreshLogView(id)
    }
    func performLogs(_ action: InputAction) {
        switch action {
        case .back: panel = nil
        case .confirm: activateLogAction()
        case .move(.left): logActionIndex = max(0, logActionIndex - 1)
        case .move(.right): logActionIndex = min(logActions.count - 1, logActionIndex + 1)
        case .move(.up): scrollLog(-90)
        case .move(.down): scrollLog(90)
        case .previousPage: scrollLog(-450)
        case .nextPage: scrollLog(450)
        default: break // Modal input must never move the library or switch tabs underneath it.
        }
    }
    private func scrollLog(_ points: Double) {
        logScrollRequest = .init(sequence: logScrollRequest.sequence + 1, points: points)
    }
    func revealLogFile() {
        guard let logDocument, let catalog, let diagnosticArchive else { return }
        Task { [weak self] in
            do {
                try await diagnosticArchive.synchronize(catalog)
                let file = try await diagnosticArchive.file(for: logDocument)
                guard case .logs(logDocument.gameID) = self?.panel else { return }
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } catch { self?.logArchiveError = "The log file could not be revealed. Check app storage and try again." }
        }
    }
    func revealLogsFolder() {
        guard let diagnosticArchive, let catalog else { return }
        Task { [weak self] in
            do {
                try await diagnosticArchive.synchronize(catalog)
                NSWorkspace.shared.open(diagnosticArchive.root)
            } catch { self?.show(.information("The logs folder could not be opened. Check app storage and try again.")) }
        }
    }
}
