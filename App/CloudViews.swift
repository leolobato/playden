import SwiftUI
import Domain

struct CloudStatusLabel: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    var body: some View {
        Button { model.showCloud(gameID) } label: {
            HStack(spacing: 10) {
                Image(systemName: "icloud").font(.system(size: 18, weight: .medium))
                Text("Cloud saves · \(model.cloudLabel(gameID))").font(Design.body(18, weight: "Medium"))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }.foregroundStyle(model.cloudStatuses[gameID]?.state == .upToDate ? Design.green : model.cloudStatuses[gameID]?.state == .conflict ? Design.amber : Design.secondary)
        }.buttonStyle(.plain).accessibilityLabel("Cloud saves: \(model.cloudLabel(gameID))")
    }
}

struct CloudSaveDialog: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    private var choices: [CloudChoice] { model.cloudChoices(gameID) }
    private var review: CloudSyncOperation? { model.cloudReview?.gameID == gameID ? model.cloudReview : nil }
    private var conflict: Bool { review?.plan?.hasConflicts == true && model.cloudStatuses[gameID]?.state == .conflict }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 22) {
                Image(systemName: conflict ? "icloud.and.arrow.down" : "icloud").font(.system(size: 36, weight: .light)).foregroundStyle(Design.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(conflict ? "Choose your saved progress" : "Cloud saves").font(Design.condensed(44))
                    Text(model.gameName(gameID)).font(Design.body(24)).foregroundStyle(Design.secondary)
                }
                Spacer()
                Text(model.cloudLabel(gameID)).font(Design.body(19, weight: "Medium"))
                    .foregroundStyle(conflict ? Design.amber : Design.secondary).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Design.text.opacity(0.06), in: Capsule())
            }
            Text(model.cloudMessage(gameID)).font(Design.body(25)).foregroundStyle(Design.secondary).lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            if conflict {
                HStack(spacing: 24) {
                    copyCard(local: true)
                    copyCard(local: false)
                }
                Label("Both copies are backed up before either is replaced.", systemImage: "checkmark.shield")
                    .font(Design.body(20)).foregroundStyle(Design.secondary)
            }
            if review?.plan?.requiresAccountConfirmation == true && !model.cloudBusy(gameID) {
                Text("Choosing a copy links this installation’s progress to the Steam account currently signed in\(model.identity.map { " (\($0.displayName))" } ?? "").")
                    .font(Design.body(21)).foregroundStyle(Design.amber).lineSpacing(5)
            }
            HStack(spacing: 18) {
                ForEach(Array(choices.enumerated()).filter { ![.local, .remote].contains($0.element) }, id: \.offset) { index, choice in
                    ActionButton(title: choice == .close && model.session.phase == .awaitingCloud ? "Cancel launch" : choice.rawValue,
                        primary: choice == .attach, focused: model.panelIndex == index, reducedMotion: model.reducedMotion) {
                        model.panelIndex = index; model.activateCloud(choice, id: gameID)
                    }
                }
                Spacer(minLength: 0)
            }.padding(.top, 4)
            HStack(spacing: 28) {
                LegendItem(glyph: keyboard ? "↵" : model.playStationGlyphs ? "✕" : "A", title: "Select")
                LegendItem(glyph: keyboard ? "ESC" : model.playStationGlyphs ? "○" : "B", title: model.session.phase == .awaitingCloud ? "Cancel launch" : "Close")
                Spacer()
                if model.cloudBusy(gameID) { Text("You can close this while sync continues.").font(Design.body(18)).foregroundStyle(Design.muted) }
            }.foregroundStyle(Design.secondary).padding(.top, 8)
        }.padding(44).frame(width: 1120)
            .background(Design.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Design.text.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 60, y: 24)
    }
    private var keyboard: Bool { model.controllerName == nil || model.keyboardNavigation }
    private func copyCard(local: Bool) -> some View {
        let choice: CloudChoice = local ? .local : .remote
        let index = choices.firstIndex(of: choice)
        let localFiles = review?.plan?.decisions.compactMap(\.local) ?? []
        let remoteFiles = review?.remote?.files.filter { $0.state == .present } ?? []
        let dates = local ? localFiles.map(\.modifiedAt) : remoteFiles.map(\.modifiedAt)
        let count = local ? localFiles.count : remoteFiles.count
        let size = local ? localFiles.reduce(Int64(0)) { $0 + $1.bytes } : remoteFiles.reduce(Int64(0)) { $0 + $1.bytes }
        return Button {
            if let index { model.panelIndex = index; model.activateCloud(choice, id: gameID) }
        } label: {
            VStack(alignment: .leading, spacing: 18) {
                Label(local ? "On this Mac" : "Steam Cloud", systemImage: local ? "desktopcomputer" : "icloud")
                    .font(Design.condensed(30)).foregroundStyle(Design.text)
                VStack(alignment: .leading, spacing: 6) {
                    Text(dates.max().map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No saved files")
                        .font(Design.body(24, weight: "Medium")).foregroundStyle(Design.text)
                    Text("\(count) \(count == 1 ? "file" : "files") · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                        .font(Design.body(20)).foregroundStyle(Design.secondary)
                }
                Text(local ? "Upload this progress to Steam Cloud." : "Download this progress to this Mac.")
                    .font(Design.body(21)).foregroundStyle(Design.secondary).lineSpacing(5)
                HStack {
                    Text(choice.rawValue).font(Design.condensed(27))
                    Spacer()
                    Image(systemName: local ? "arrow.up.to.line" : "arrow.down.to.line").font(.system(size: 20, weight: .medium))
                }.foregroundStyle(Design.accent).padding(.top, 4)
            }.padding(28).frame(maxWidth: .infinity, minHeight: 245, alignment: .topLeading)
                .background(Design.text.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Design.text.opacity(0.13), lineWidth: 1))
                .focusRing(index != nil && model.panelIndex == index)
        }.buttonStyle(.plain).disabled(index == nil)
    }
}
