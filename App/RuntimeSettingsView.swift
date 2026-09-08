import SwiftUI
import Domain
import Runner

/// Settings shows the installed runtime's current state. The first-run wizard is reserved for
/// onboarding, and progress appears here only while an actual setup operation is running.
struct RuntimeSettingsView: View {
    @Bindable var model: LibraryModel
    private var ready: Bool { model.runtimeInfo?.templateReady == true && model.setupFailure == nil }
    private var status: String {
        if model.runtimeChecking { return "Checking game setup…" }
        if model.setupBusy {
            return switch model.templateStage {
            case .checking: "Checking CrossOver…"
            case .creating: "Creating game setup…"
            case .configuring: "Applying game settings…"
            case .validating: "Verifying game setup…"
            case .ready: "Finishing setup…"
            }
        }
        if ready { return "Ready for Windows games" }
        return model.setupFailure == nil ? "Games are not set up yet" : "Game setup needs attention"
    }
    private var explanation: String {
        if model.runtimeChecking { return "Looking for CrossOver and checking your saved game setup." }
        if model.setupBusy { return "This can take a moment. You can stop setup and continue browsing your library." }
        if let failure = model.setupFailure { return failure.reason }
        if ready { return "CrossOver and your game setup are available. You can install and play Windows games." }
        return "Prepare the shared setup that Playden uses for new Windows game installations."
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Design.background
            LinearGradient(colors: [Design.accent.opacity(0.035), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            SectionLabel(text: "Settings / Library").offset(x: 96, y: 60)
            VStack(alignment: .leading, spacing: 18) {
                Text("Runtime").font(Design.condensed(64))
                Text("CrossOver runs your Windows games. Each game has its own setup.")
                    .font(Design.body(28)).foregroundStyle(Design.secondary)
            }.offset(x: 96, y: 132)
            HStack(alignment: .top, spacing: 28) {
                Group {
                    if model.runtimeChecking || model.setupBusy { ProgressView().controlSize(.large).tint(Design.accent) }
                    else { Image(systemName: ready ? "checkmark.circle" : "exclamationmark.circle").font(.system(size: 44, weight: .regular)).foregroundStyle(ready ? Design.green : Design.amber) }
                }.frame(width: 52, height: 56)
                VStack(alignment: .leading, spacing: 14) {
                    Text(status).font(Design.condensed(38))
                    Text(explanation).font(Design.body(26)).foregroundStyle(Design.secondary).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(34).frame(width: 1728, alignment: .leading).frame(minHeight: 160, alignment: .leading)
                .background(Design.text.opacity(0.045), in: RoundedRectangle(cornerRadius: 12)).offset(x: 96, y: 284)
            VStack(alignment: .leading, spacing: 28) {
                SectionLabel(text: "Runtime details")
                component("CrossOver", model.runtimeInfo?.version ?? (model.runtimeChecking ? "Checking…" : "Unavailable"))
                component("Game setup", model.runtimeInfo.map { "Version \($0.templateVersion)" + ($0.templateReady ? "" : " · Not ready") } ?? "Not checked")
                Rectangle().fill(Design.text.opacity(0.1)).frame(height: 1)
                Text("Check again refreshes the status. Preparing the shared setup keeps your installed games and their saves.")
                    .font(Design.body(24)).foregroundStyle(Design.secondary).lineSpacing(7).fixedSize(horizontal: false, vertical: true)
            }.frame(width: 1040, alignment: .leading).offset(x: 96, y: 510)
            VStack(alignment: .leading, spacing: 24) {
                SectionLabel(text: "Actions")
                ForEach(Array(model.setupActions.enumerated()), id: \.offset) { index, action in
                    ActionButton(title: action, primary: index == 0, focused: model.setupIndex == index,
                                 large: index == 0, reducedMotion: model.reducedMotion) {
                        model.setupIndex = index; model.activateSetup()
                    }
                }
            }.frame(width: 540, alignment: .leading).offset(x: 1284, y: 510)
            HStack(spacing: 30) {
                LegendItem(glyph: model.controllerName == nil ? "↵" : model.playStationGlyphs ? "✕" : "A", title: "Select")
                LegendItem(glyph: model.controllerName == nil ? "ESC" : model.playStationGlyphs ? "○" : "B", title: model.setupBusy ? "Stop setup" : "Back to settings")
            }.offset(x: 96, y: 986)
        }.frame(width: 1920, height: 1080).foregroundStyle(Design.text)
    }
    private func component(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(Design.condensed(30))
            Spacer()
            Text(value).font(Design.body(26)).foregroundStyle(Design.secondary)
        }
    }
}
