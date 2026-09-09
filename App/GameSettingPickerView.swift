import SwiftUI
import Domain

/// Minimal placeholder; the real layout for the setting picker lands in a later step.
struct GameSettingPicker: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    let setting: RuntimeSettingID
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(GameSettingsCatalog.definition(setting).title).font(Design.condensed(40))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.pickerChoices(gameID, setting).enumerated()), id: \.offset) { index, choice in
                        HStack {
                            Text(choice.name).font(Design.body(24))
                            Spacer()
                            if let meta = model.pickerMeta(gameID, setting, choice: choice) {
                                Text(meta).font(Design.body(18)).foregroundStyle(Design.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .focusRing(model.pickerIndex == index)
                    }
                }
            }
        }.padding(40).frame(width: 960).frame(maxHeight: .infinity)
            .background(Design.panel).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}
