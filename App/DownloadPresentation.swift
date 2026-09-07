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
    var activeDownload: Game? { games.first { $0.status == .downloading } }
    var downloadGames: [Game] {
        let active = games.filter { $0.status == .downloading }
        let queued = games.filter { $0.status == .queued }.sorted {
            (queueOrder.firstIndex(of: $0.id) ?? Int.max) < (queueOrder.firstIndex(of: $1.id) ?? Int.max)
        }
        let completed = games.filter { completedDownloads.contains($0.id) && $0.status == .installed }
        return active + queued + completed
    }
    var pendingDownloadCount: Int { games.filter { [.queued, .downloading].contains($0.status) }.count }
    var downloadRows: [DownloadRow] {
        var previousSection = "", top = 24.0
        return downloadGames.enumerated().map { index, game in
            let section = game.status == .downloading ? "Downloading now" : game.status == .queued ? "Queued" : "Recently finished"
            let heading: String? = section != previousSection ? section : nil
            if heading != nil && index > 0 { top += 20 }
            let headingTop = top
            if heading != nil { top += 36 }
            let height = game.status == .downloading ? 220.0 : 118.0
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
        guard let game = games.first(where: { $0.id == id }) else { return [] }
        switch game.status {
        case .downloading: return [downloadPaused ? "Resume" : "Pause", "Cancel download…", "Open game", "View logs"]
        case .queued: return ["Move up", "Move down", "Cancel download…", "Open game"]
        default: return ["Open game", "View logs", "Dismiss"]
        }
    }
    func activateDownloadAction(_ label: String, id: GameID) {
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
