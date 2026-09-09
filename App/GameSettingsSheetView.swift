import SwiftUI
import Domain

/// Minimal placeholder; the real layout for the settings sheet lands in a later step.
struct GameSettingsSheet: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Game settings").font(Design.condensed(40))
            Text(model.gameName(gameID)).font(Design.body(24)).foregroundStyle(Design.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.settingsRows(for: gameID).enumerated()), id: \.offset) { index, row in
                        Text(rowTitle(row)).font(Design.body(24))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .focusRing(model.settingsFocus == index)
                    }
                }
            }
            if let error = model.gameSettingsError { Text(error).font(Design.body(20)).foregroundStyle(Design.red) }
        }.padding(40).frame(width: 960).frame(maxHeight: .infinity)
            .background(Design.panel).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
    private func rowTitle(_ row: GameSettingsRow) -> String {
        switch row {
        case .profile: "\(GameSettingsCatalog.profileTitle) · \(model.profileLabel(gameID))"
        case .moreSettings: model.moreSettingsExpanded ? "Fewer settings" : "More settings"
        case .setting(let id): "\(GameSettingsCatalog.definition(id).title) · \(model.rowValueLabel(gameID, id))"
        case .resetAll: "Reset all"
        }
    }
}
