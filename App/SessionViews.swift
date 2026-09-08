import SwiftUI
import Sessions

struct LaunchingGameView: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack(alignment: .top) {
            Design.background
            AmbientBackdrop(url: model.sessionGame?.heroURL ?? model.sessionGame?.coverURL, reducedMotion: model.reducedMotion)
            VStack(spacing: 38) {
                Artwork(url: model.sessionGame?.coverURL, title: model.sessionGame?.title ?? "Game")
                    .frame(width: 240, height: 360).clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 20) {
                    ActivitySpinner(reducedMotion: model.reducedMotion, label: "Launching")
                    Text(model.session.phase == .syncingSaves ? "Syncing saves for \(model.sessionGame?.title ?? "game")…" : "Launching \(model.sessionGame?.title ?? "game")…").font(Design.condensed(44))
                        .lineLimit(2).multilineTextAlignment(.center)
                }.frame(maxWidth: 1300)
            }.offset(y: 318)
            HStack(spacing: 14) {
                if model.session.phase == .syncingSaves {
                    LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "ESC" : model.playStationGlyphs ? "○" : "B", title: "Save sync")
                } else {
                LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "⇧ HOME" : model.playStationGlyphs ? "PS" : "HOME",
                           title: model.controllerName == nil || model.keyboardNavigation ? "Game controls" : "Hold for one second to quit")
                }
            }.foregroundStyle(Design.secondary).offset(y: 986)
        }.frame(width: 1920, height: 1080).foregroundStyle(Design.text)
    }
}
struct ActivitySpinner: View {
    var reducedMotion: Bool
    var label: String
    @State private var spinning = false
    var body: some View {
        Circle().trim(from: 0.12, to: 0.88).stroke(Design.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .frame(width: 32, height: 32).rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear { if !reducedMotion { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spinning = true } } }
            .accessibilityLabel(label)
    }
}
struct GameExitOverlay: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 18) {
                    Artwork(url: model.sessionGame?.coverURL, title: model.sessionGame?.title ?? "Game")
                        .frame(width: 64, height: 96).clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.sessionGame?.title ?? "Game").font(Design.condensed(40)).lineLimit(2)
                        Text(status).font(Design.body(24)).foregroundStyle(Design.secondary)
                    }
                    Spacer(minLength: 0)
                }
                VStack(spacing: 12) {
                    exitButton("Return to game", index: 0) { model.returnToGame() }
                    exitButton(model.sessionBusy ? "Quitting…" : "Quit game", index: 1) { model.quitGame() }
                }
                Text(model.sessionIssue?.reason ?? "Quit asks the game to close first and forces it after 10 seconds. Unsaved progress may be lost.")
                    .font(Design.body(21)).foregroundStyle(model.sessionIssue == nil ? Design.muted : Design.amber)
                    .lineSpacing(5).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }.padding(44).frame(width: 810)
                .background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Design.text.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 50, y: 24)
            HStack(spacing: 32) {
                LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "↵" : model.playStationGlyphs ? "✕" : "A", title: "Select")
                LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "ESC" : model.playStationGlyphs ? "○" : "B", title: "Return to game")
            }.offset(y: 466)
        }.frame(width: 1920, height: 1080).foregroundStyle(Design.text)
    }
    private var status: String {
        if model.sessionBusy || model.session.phase == .stopping { return "Stopping game…" }
        if model.isLaunchingGame { return "Launching…" }
        let minutes = (model.session.session?.playedSeconds ?? 0) / 60
        return "Running · \(minutes < 1 ? "Less than a minute" : "\(minutes) min") this session"
    }
    private func exitButton(_ title: String, index: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Design.condensed(32)).frame(maxWidth: .infinity).frame(height: 80)
                .foregroundStyle(index == 0 ? Color(hex: 0x1A1210) : Design.text)
                .background(index == 0 ? Design.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(index == 0 ? .clear : Design.text.opacity(0.2), lineWidth: 2))
                .focusRing(model.exitIndex == index)
        }.buttonStyle(.plain).disabled(model.sessionBusy)
    }
}
struct ScaledGameExitOverlay: View {
    @Bindable var model: LibraryModel
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 1920, geometry.size.height / 1080)
            GameExitOverlay(model: model).scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }.preferredColorScheme(.dark)
    }
}
