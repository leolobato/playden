import SwiftUI

struct ResetAppDataDialog: View {
    @Bindable var model: LibraryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 22) {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 38, weight: .light)).foregroundStyle(Design.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reset Playden?").font(Design.condensed(46))
                    Text("Sign out and start setup again.").font(Design.body(25)).foregroundStyle(Design.secondary)
                }
            }
            HStack(alignment: .top, spacing: 24) {
                summary("What resets", symbol: "arrow.counterclockwise", lines: [
                    "Steam sign-in", "Favorites, hidden games and collections", "Compatibility ratings and notes", "Library and display settings"
                ])
                summary("What stays", symbol: "checkmark.shield", lines: [
                    "Installed games and saves", "Download progress and play history", "Cloud recovery copies", "Installation and session diagnostics"
                ])
            }
            Text("You can sign in again to restore your Steam library. Paused downloads stay paused.")
                .font(Design.body(23)).foregroundStyle(Design.secondary).lineSpacing(5)
            if let message = model.resetError ?? model.resetBlocker {
                Label(message, systemImage: "exclamationmark.circle").font(Design.body(23)).foregroundStyle(Design.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.resetBusy {
                HStack(spacing: 16) {
                    ActivitySpinner(reducedMotion: model.reducedMotion, label: "Resetting app data")
                    Text("Signing out and resetting app data…").font(Design.body(25))
                }.frame(height: 64)
            } else {
                HStack(spacing: 20) {
                    ForEach(Array(model.resetActions.enumerated()), id: \.offset) { index, action in
                        ActionButton(title: model.resetActionTitle(action), primary: action == .reset,
                            focused: model.panelIndex == index, reducedMotion: model.reducedMotion) {
                            model.panelIndex = index; model.activateReset(action)
                        }
                    }
                    Spacer()
                }
                HStack(spacing: 28) {
                    LegendItem(glyph: keyboard ? "↵" : model.playStationGlyphs ? "✕" : "A", title: "Select")
                    LegendItem(glyph: keyboard ? "ESC" : model.playStationGlyphs ? "○" : "B", title: "Cancel")
                }.foregroundStyle(Design.secondary)
            }
        }.padding(44).frame(width: 1120)
            .background(Design.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Design.text.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 60, y: 24)
    }
    private var keyboard: Bool { model.controllerName == nil || model.keyboardNavigation }
    private func summary(_ title: String, symbol: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol).font(Design.condensed(30)).foregroundStyle(Design.text)
            ForEach(lines, id: \.self) { line in Text(line).font(Design.body(22)).foregroundStyle(Design.secondary) }
        }.padding(28).frame(maxWidth: .infinity, minHeight: 265, alignment: .topLeading)
            .background(Design.text.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}
