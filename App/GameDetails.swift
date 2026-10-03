import SwiftUI
import Domain

extension LibraryModel {
    /// The installed game folder, or the app itself for games on this Mac.
    func installFolder(_ game: Game) -> URL? {
        if game.isExternal { return game.appURL }
        return installLocations[game.id].map { $0.lastKnownRoot.appendingPathComponent($0.relativePath, isDirectory: true) }
    }
    /// The drive's name while it's connected.
    func installDriveName(_ game: Game) -> String? {
        guard !game.isExternal, let location = installLocations[game.id] else { return nil }
        return availableVolumes.first { $0.id == location.volumeID }?.name
    }
    func revealInstallFolder(_ id: GameID) {
        guard let game = games.first(where: { $0.id == id }), let folder = installFolder(game) else { return }
        if isPreview { show(.information("This is the design preview. Show in Finder opens the game’s folder when connected.")); return }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            show(.information("\(game.title)’s folder isn’t available. Reconnect its drive, or locate the game again."))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

struct GameDetailsSummary: View {
    @Bindable var model: LibraryModel
    let game: Game
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let folder = model.installFolder(game) {
                row(game.status == .installed ? "Location" : "Last known location", (folder.path as NSString).abbreviatingWithTildeInPath)
            }
            if let drive = model.installDriveName(game) { row("Drive", drive) }
            if let installed = game.installedAt { row("Installed", installed.formatted(date: .abbreviated, time: .omitted)) }
            if let bytes = game.knownInstalledBytes { row("Size", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        }.frame(width: 520, alignment: .leading)
    }
    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(Design.condensed(16)).tracking(1.6).foregroundStyle(Design.secondary)
            Text(value).font(Design.body(24, weight: "Medium")).lineLimit(4).truncationMode(.middle).textSelection(.enabled)
        }
    }
}
