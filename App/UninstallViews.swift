import SwiftUI
import Domain

struct UninstallDialog: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    private var warning: Bool { model.uninstallPhase == .unsynced }
    private var keyboard: Bool { model.controllerName == nil || model.keyboardNavigation }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 22) {
                Image(systemName: warning ? "exclamationmark.icloud" : "trash").font(.system(size: 34, weight: .light)).foregroundStyle(warning ? Design.amber : Design.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(warning ? "Unsynced progress will be lost" : model.uninstallBusy ? "Preparing to uninstall" : "Uninstall \(model.gameName(gameID))?")
                        .font(Design.condensed(42)).fixedSize(horizontal: false, vertical: true)
                    if warning || model.uninstallBusy { Text(model.gameName(gameID)).font(Design.body(24)).foregroundStyle(Design.secondary) }
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 24) {
                summary(title: "Removed from this Mac", icon: "minus.circle", lines: [size + " of game files", "Game runtime and local saves"], color: Design.red)
                summary(title: "Kept in your library", icon: "checkmark.circle", lines: ["Collections, favorites and rating", "Playtime and Steam Cloud saves"], color: Design.green)
            }
            Text(model.uninstallBusy ? "Closing this game if needed and checking saved progress before removal…" : warning ? "Only saves already uploaded to Steam Cloud can be restored after reinstalling. Discarding removes this Mac’s unsynced progress." : "Big Screen checks Steam Cloud before removing local saves. You’ll be asked again if any progress could not be synced.")
                .font(Design.body(24)).foregroundStyle(Design.secondary).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
            if let message = model.uninstallError {
                Text(message).font(Design.body(21)).foregroundStyle(warning ? Design.amber : Design.red).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 18) {
                ForEach(Array(model.uninstallChoices(gameID).enumerated()), id: \.offset) { index, choice in
                    ActionButton(title: choice == .remove && model.hasActiveSession && model.session.session?.gameID == gameID ? "Quit and uninstall" : choice.rawValue,
                        primary: choice == .remove || choice == .discard, focused: model.panelIndex == index, reducedMotion: model.reducedMotion) {
                        model.panelIndex = index; model.activateUninstall(choice, id: gameID)
                    }
                }
                Spacer(minLength: 0)
            }.padding(.top, 8)
            HStack(spacing: 28) {
                LegendItem(glyph: keyboard ? "↵" : model.playStationGlyphs ? "✕" : "A", title: "Select")
                LegendItem(glyph: keyboard ? "ESC" : model.playStationGlyphs ? "○" : "B", title: "Cancel")
                Spacer()
            }.foregroundStyle(Design.secondary)
        }.padding(44).frame(width: 1120)
            .background(Design.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Design.text.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 60, y: 24)
    }
    private var size: String {
        model.uninstallInstallation.map { ByteCountFormatter.string(fromByteCount: $0.installedBytes, countStyle: .file) }
            ?? model.games.first(where: { $0.id == gameID })?.size ?? "Game files"
    }
    private func summary(title: String, icon: String, lines: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(Design.condensed(28)).foregroundStyle(color)
            ForEach(lines, id: \.self) { Text($0).font(Design.body(22)).foregroundStyle(Design.secondary) }
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
