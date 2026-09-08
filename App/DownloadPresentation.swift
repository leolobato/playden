import Foundation
import Domain
import Focus

struct DownloadRow: Identifiable {
    var id: GameID { game.id }
    let game: Game
    let index: Int
    let top: Double
    let height: Double
    let heading: String?
    let headingTop: Double
}
extension LibraryModel {
    var activeDownload: Game? {
        if !isPreview { return visibleInstallJobs.first(where: { $0.id == activeInstallID }).map { game(for: $0) } }
        return games.first { $0.status == .downloading }
    }
    var downloadGames: [Game] {
        if !isPreview { return visibleInstallJobs.map { game(for: $0) } }
        let active = games.filter { $0.status == .downloading }
        let queued = games.filter { $0.status == .queued }.sorted {
            (queueOrder.firstIndex(of: $0.id) ?? Int.max) < (queueOrder.firstIndex(of: $1.id) ?? Int.max)
        }
        let completed = games.filter { completedDownloads.contains($0.id) && $0.status == .installed }
        return active + queued + completed
    }
    var pendingDownloadCount: Int {
        isPreview ? games.filter { [.queued, .downloading].contains($0.status) }.count : visibleInstallJobs.filter { ![.completed, .cancelled].contains($0.state) }.count
    }
    var downloadRows: [DownloadRow] {
        var previousSection = "", top = 24.0
        return downloadGames.enumerated().map { index, game in
            let job = isPreview ? nil : liveJob(for: game.id)
            let section = job.map { $0.id == activeInstallID ? ($0.kind == .uninstall ? "Removing now" : $0.kind == .repair ? "Verifying now" : "Installing now") : $0.state == .failed ? "Needs attention" : [.completed, .cancelled].contains($0.state) ? "Recently finished" : "Queued" }
                ?? (game.status == .downloading ? "Downloading now" : game.status == .queued ? "Queued" : "Recently finished")
            let heading: String? = section != previousSection ? section : nil
            if heading != nil && index > 0 { top += 20 }
            let headingTop = top
            if heading != nil { top += 36 }
            let height = (job.map { $0.id == activeInstallID } ?? (game.status == .downloading)) ? 220.0 : job?.state == .failed ? 160.0 : 118.0
            let row = DownloadRow(game: game, index: index, top: top, height: height, heading: heading, headingTop: headingTop)
            previousSection = section; top += height + 12
            return row
        }
    }
    func revealDownloadFocus() {
        guard let row = downloadRows[safe: downloadIndex], let last = downloadRows.last else { downloadScrollOffset = 0; return }
        downloadScrollOffset = FocusViewport.reveal(offset: downloadScrollOffset, itemMin: row.heading == nil ? row.top : row.headingTop, itemMax: row.top + row.height,
            viewport: 840, content: last.top + last.height + 24)
    }
    func downloadActions(for id: GameID) -> [String] {
        if !isPreview, let job = liveJob(for: id) {
            let common = ["Open game", "View logs"]
            if job.kind == .uninstall { return (job.state == .failed ? ["Retry"] : []) + common }
            let cancel = job.kind == .repair ? "Stop verifying…" : "Cancel download…"
            if [.completed, .cancelled].contains(job.state) { return common }
            if job.cancellationRequested == true { return (job.state == .paused || job.state == .failed ? ["Retry cancellation"] : []) + common }
            switch job.state {
            case .running: return ["Pause", cancel] + common
            case .stopping: return common
            case .paused: return (job.pauseReasons == [.gameplay] ? [] : ["Resume"]) + [cancel] + common
            case .failed: return ["Retry", cancel] + common
            default: return ["Pause", "Move up", "Move down", cancel] + common
            }
        }
        guard let game = games.first(where: { $0.id == id }) else { return [] }
        switch game.status {
        case .downloading: return [downloadPaused ? "Resume" : "Pause", "Cancel download…", "Open game", "View logs"]
        case .queued: return ["Move up", "Move down", "Cancel download…", "Open game"]
        default: return ["Open game", "View logs", "Dismiss"]
        }
    }
    func activateDownloadAction(_ label: String, id: GameID) {
        if !isPreview { performLiveDownloadAction(label, id: id); return }
        switch label {
        case "Pause", "Resume": downloadPaused.toggle(); panel = nil
        case "Cancel download…": show(.confirmation(.cancelDownload(id)))
        case "Open game": if let game = games.first(where: { $0.id == id }) { openGame(game) }
        case "View logs": show(.logs(id))
        case "Dismiss": completedDownloads.remove(id); panel = nil; reconcileFocus()
        case "Move up", "Move down":
            var order = downloadGames.filter { $0.status == .queued }.map(\.id)
            guard let index = order.firstIndex(of: id) else { return }
            let target = index + (label == "Move up" ? -1 : 1)
            guard order.indices.contains(target) else { return }
            order.swapAt(index, target); queueOrder = order
            downloadIndex = downloadGames.firstIndex(where: { $0.id == id }) ?? 0
        default: break
        }
    }
}
