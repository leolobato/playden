import Foundation
import Domain

extension LibraryModel {
    var hasDismissedFailedDownloads: Bool {
        latestInstallJobs.contains { $0.state == .failed && downloadDismissals[$0.id]?.hides($0) == true }
    }
    func loadDownloadHistory() {
        guard !isPreview, let catalog else { return }
        do { downloadDismissals = Dictionary(uniqueKeysWithValues: try catalog.jobHistoryDismissals().map { ($0.jobID, $0) }) }
        catch { installPersistenceError = "Download history could not be read. All jobs remain visible." }
    }
    func dismissDownloadHistory(_ job: JobRecord) {
        guard job.canDismissHistory, let catalog else { return }
        do {
            let dismissal = try catalog.dismissJobHistory(job)
            downloadDismissals[job.id] = dismissal
            panel = nil; reconcileFocus(); revealDownloadFocus()
            if downloadGames.isEmpty { tabsFocused = true }
        } catch { show(.information((error as? OperationFailure)?.reason ?? "Download history could not be saved. Try again.")) }
    }
    func revealDownloadHistory(for id: GameID) {
        do {
            if let job = liveJob(for: id) {
                try catalog?.revealJobHistory(job.id)
                downloadDismissals.removeValue(forKey: job.id)
            }
            selectTab(.downloads)
            downloadIndex = downloadGames.firstIndex { $0.id == id } ?? 0
            revealDownloadFocus()
        } catch { show(.information("This download's history could not be opened. Try again.")) }
    }
    var downloadHistoryNote: String? {
        guard case .downloadActions(let id) = panel, let job = liveJob(for: id), job.canDismissHistory else { return nil }
        return job.state == .failed
            ? "Dismiss hides this entry. Open the game page to review or retry unfinished work."
            : "Dismiss hides this entry. Your game and its logs stay available."
    }
}
