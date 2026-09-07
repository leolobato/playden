import SwiftUI
import Domain

struct PanelActionList: View {
    @Bindable var model: LibraryModel
    var body: some View {
        let offset = max(0, Double(model.panelIndex - 5) * 80)
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.panelActions.enumerated()), id: \.offset) { index, title in
                Button { model.panelIndex = index; model.activatePanel() } label: {
                    HStack {
                        if model.panel == .compatibility && index < 4 {
                            Circle().fill([Design.muted, Design.green, Design.amber, Design.red][index]).frame(width: 12, height: 12)
                        }
                        Text(title).font(Design.body(26, weight: "Medium")).lineLimit(1)
                        Spacer(minLength: 8)
                        if model.panelItemSelected(at: index) { Image(systemName: "checkmark").foregroundStyle(Design.accent) }
                    }.padding(.horizontal, 18).frame(width: 520, height: 68)
                        .background(model.panelIndex == index ? Design.text.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .focusRing(model.panelIndex == index, compact: true)
                }.buttonStyle(.plain).offset(x: 12, y: 12 + Double(index) * 80 - offset)
            }
        }.frame(width: 544, height: min(560, Double(model.panelActions.count) * 80 + 24), alignment: .topLeading)
            .clipped().padding(.leading, -12)
            .animation(model.reducedMotion ? nil : .easeOut(duration: 0.18), value: offset)
    }
}
struct ConfirmDialog: View {
    @Bindable var model: LibraryModel
    let intent: Confirmation
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(model.confirmationTitle(intent)).font(Design.condensed(40)).fixedSize(horizontal: false, vertical: true)
            Text(model.confirmationMessage(intent)).font(Design.body(24)).foregroundStyle(Design.secondary).lineSpacing(6)
            if case .uninstall = intent {
                HStack {
                    Text("Keep saves").font(Design.body(24, weight: "Medium"))
                    Spacer()
                    Glyph(text: model.playStationGlyphs ? "□" : "X")
                    Image(systemName: model.keepSaves ? "checkmark.square.fill" : "square").font(.system(size: 32)).foregroundStyle(Design.accent)
                }.padding(18).background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)).onTapGesture { model.keepSaves.toggle() }
            }
            HStack(spacing: 20) {
                ForEach(Array(model.panelActions.enumerated()), id: \.offset) { index, title in
                    Button { model.panelIndex = index; model.activatePanel() } label: {
                        Text(title).font(Design.condensed(28)).frame(maxWidth: .infinity).frame(height: 68)
                            .background(index == 1 ? (isInstall ? Design.accent.opacity(0.18) : Design.red.opacity(0.18)) : Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(index == 1 ? (isInstall ? Design.accent : Design.red).opacity(0.5) : Design.text.opacity(0.2), lineWidth: 2))
                            .focusRing(model.panelIndex == index)
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 12)
        }.padding(40).frame(width: 720).background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.7), radius: 50, y: 40)
    }
    private var isInstall: Bool { if case .install = intent { true } else { false } }
}
struct LogViewer: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack { Text(model.gameName(gameID)).font(Design.condensed(40)); Text("· Logs").font(Design.condensed(40)).foregroundStyle(Design.secondary); Spacer(); Text("No sessions yet").font(Design.body(22)).foregroundStyle(Design.muted) }
            VStack(alignment: .leading, spacing: 20) {
                Text("No installation or play-session logs yet.").foregroundStyle(Design.text)
                Text("This library is using preview data. Logs will appear here after Steam and the game runtime are connected.").foregroundStyle(Design.secondary)
            }.font(.system(size: 22, design: .monospaced)).padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(hex: 0x0A0908), in: RoundedRectangle(cornerRadius: 8))
            ActionButton(title: "Close", primary: true, focused: true, reducedMotion: model.reducedMotion) { model.panel = nil }
        }.padding(40).frame(width: 1728, height: 864).background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}
