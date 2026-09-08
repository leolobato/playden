import AppKit
import Domain
import Input

struct LogScrollRequest: Equatable {
    var sequence = 0
    var points = 0.0
}

extension LibraryModel {
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
        do { logDocument = try catalog.diagnosticLogs(for: id).first }
        catch { logArchiveError = "The saved log could not be read. Try again." }
    }
    func prepareLogView(_ id: GameID) {
        logDocument = nil; logScrollRequest = .init(); logScrollFraction = 0; logCanScroll = false; logActionIndex = 0
        refreshLogView(id)
    }
    func performLogs(_ action: InputAction) {
        switch action {
        case .back: panel = nil
        case .confirm: if logActionIndex == 0 { panel = nil } else { revealLogFile() }
        case .move(.left): logActionIndex = 0
        case .move(.right): if logDocument != nil && diagnosticArchive != nil { logActionIndex = 1 }
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
