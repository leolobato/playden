import SwiftUI
import Domain

/// Minimal placeholder; the real layout for the profile chooser lands in a later step.
struct ProfileChooser: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a profile").font(Design.condensed(40))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.chooserRows(gameID).enumerated()), id: \.offset) { index, row in
                        Text(row?.name ?? "Custom").font(Design.body(24))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .focusRing(model.chooserIndex == index)
                    }
                }
            }
        }.padding(40).frame(width: 960).frame(maxHeight: .infinity)
            .background(Design.panel).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}
