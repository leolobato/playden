import SwiftUI
import Domain

extension LibraryModel {
    func showGameSettings(_ id: GameID) {
        controllerModeChoice = controllerModes[id]
        gameSettingsError = nil
        show(.gameSettings(id))
        panelIndex = controllerModeChoice == nil ? 0 : controllerModeChoice == .xboxCompatible ? 1 : 2
    }

    func activateGameSettings(_ id: GameID) {
        if panelIndex < 3 {
            controllerModeChoice = panelIndex == 0 ? nil : panelIndex == 1 ? .xboxCompatible : .native
            return
        }
        if panelIndex == 3 { panel = nil; return }
        guard panelIndex == 4 else { return }
        do {
            if let catalog {
                guard let entry = try catalog.snapshot().entries.first(where: { $0.id == id }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                var edits = entry.edits
                edits.controllerMode = controllerModeChoice
                try catalog.saveEdits(edits, for: id)
            } else if !isPreview { throw CocoaError(.fileWriteUnknown) }
            controllerModes[id] = controllerModeChoice
            panel = nil
        } catch {
            gameSettingsError = "Could not save game settings. Try again."
        }
    }
}

struct GameSettingsDialog: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    private let descriptions = [
        "Currently \(ControllerMode.playdenDefault.title). Follows Playden’s default.",
        "Works with games that expect an Xbox controller.",
        "Uses the controller’s native input. Support depends on the game."
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Game settings").font(Design.condensed(40))
            Text(model.gameName(gameID)).font(Design.body(24)).foregroundStyle(Design.secondary)
            Text("Controller mode").font(Design.condensed(32))
            VStack(spacing: 12) {
                ForEach(0..<3) { index in
                    let selected = index == 0 ? model.controllerModeChoice == nil : index == 1 ? model.controllerModeChoice == .xboxCompatible : model.controllerModeChoice == .native
                    Button { model.panelIndex = index; model.activateGameSettings(gameID) } label: {
                        HStack(spacing: 18) {
                            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 25)).foregroundStyle(selected ? Design.accent : Design.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(["Use Playden default", "Xbox compatible", "Native controller"][index]).font(Design.body(26, weight: "Medium"))
                                Text(descriptions[index]).font(Design.body(22)).foregroundStyle(Design.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .focusRing(model.panelIndex == index)
                    }.buttonStyle(.plain)
                }
            }.padding(8)
            Text("Applies on next launch. Xbox compatible mode may limit PlayStation-specific features.")
                .font(Design.body(22)).foregroundStyle(Design.secondary)
            if let error = model.gameSettingsError { Text(error).font(Design.body(22)).foregroundStyle(Design.red) }
            HStack(spacing: 20) {
                ActionButton(title: "Cancel", focused: model.panelIndex == 3, reducedMotion: model.reducedMotion) { model.panel = nil }
                ActionButton(title: "Save", primary: true, focused: model.panelIndex == 4, reducedMotion: model.reducedMotion) {
                    model.panelIndex = 4; model.activateGameSettings(gameID)
                }
            }
        }.padding(40).frame(width: 840).background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.7), radius: 50, y: 40)
    }
}
