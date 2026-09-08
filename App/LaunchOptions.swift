import SwiftUI
import Domain

extension LibraryModel {
    func showLaunchOptions(for id: GameID, play: Bool) {
        guard let options = gameLaunchOptions[id], !options.isEmpty else { return }
        let saved = preferredLaunchOptions[id].flatMap { options.firstIndex(of: $0) }
        launchChoiceIndex = saved ?? 0
        launchAlwaysUse = saved != nil
        launchAfterChoosing = play
        launchChoiceError = nil
        show(.launchOptions(id))
        panelIndex = launchChoiceIndex
    }

    func activateLaunchChoice(for id: GameID) {
        let options = gameLaunchOptions[id] ?? []
        if options.indices.contains(panelIndex) { launchChoiceIndex = panelIndex; return }
        if panelIndex == options.count { launchAlwaysUse.toggle(); return }
        if panelIndex == options.count + 1 { panel = nil; return }
        guard panelIndex == options.count + 2, let choice = options[safe: launchChoiceIndex] else { return }
        do {
            if let catalog {
                guard let entry = try catalog.snapshot().entries.first(where: { $0.id == id }),
                      let installed = entry.installation, let plan = installed.plan else {
                    throw OperationFailure(stage: "Launch options", reason: "This game is no longer installed.", output: "")
                }
                let current = try plan.launchOptions ?? source?.installer(for: installed.game).launchOptions(plan) ?? []
                guard current.contains(choice) else {
                    throw OperationFailure(stage: "Launch options", reason: "This game's launch options changed. Close this dialog and try again.", output: "")
                }
                var edits = entry.edits
                edits.preferredLaunchOption = launchAlwaysUse ? choice : nil
                try catalog.saveEdits(edits, for: id)
            }
            preferredLaunchOptions[id] = launchAlwaysUse ? choice : nil
            panel = nil
            if launchAfterChoosing { beginPlay(id, launchOption: choice) }
        } catch {
            launchChoiceError = (error as? OperationFailure)?.reason ?? "Could not save launch options. Try again."
        }
    }
}

struct LaunchOptionsDialog: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    private var options: [LaunchOption] { model.gameLaunchOptions[gameID] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Launch options").font(Design.condensed(40))
            Text(model.games.first { $0.id == gameID }?.title ?? "Choose how to launch this game")
                .font(Design.body(24)).foregroundStyle(Design.secondary)
            if options.count <= 3 {
                optionRows
            } else {
                ScrollViewReader { scroll in
                    ScrollView { optionRows }.frame(height: 360)
                        .onChange(of: model.panelIndex) { _, index in
                            if options.indices.contains(index) { scroll.scrollTo(index, anchor: .center) }
                        }
                }
            }
            Button { model.panelIndex = options.count; model.activateLaunchChoice(for: gameID) } label: {
                HStack(spacing: 16) {
                    Image(systemName: model.launchAlwaysUse ? "checkmark.square.fill" : "square")
                        .foregroundStyle(model.launchAlwaysUse ? Design.accent : Design.secondary)
                    Text("Always use this").font(Design.body(26))
                    Spacer()
                }.font(Design.body(26)).padding(16).focusRing(model.panelIndex == options.count)
            }.buttonStyle(.plain)
            Text("Change this later from the game’s More menu → Launch options.")
                .font(Design.body(22)).foregroundStyle(Design.secondary)
            if let error = model.launchChoiceError { Text(error).font(Design.body(22)).foregroundStyle(Design.red) }
            HStack(spacing: 20) {
                ActionButton(title: "Cancel", focused: model.panelIndex == options.count + 1, reducedMotion: model.reducedMotion) { model.panel = nil }
                ActionButton(title: model.launchAfterChoosing ? "Play" : "Save", primary: true, focused: model.panelIndex == options.count + 2, reducedMotion: model.reducedMotion) {
                    model.panelIndex = options.count + 2; model.activateLaunchChoice(for: gameID)
                }
            }
        }.padding(40).frame(width: 800).background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.7), radius: 50, y: 40)
    }
    private var optionRows: some View {
        VStack(spacing: 12) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                Button { model.panelIndex = index; model.activateLaunchChoice(for: gameID) } label: {
                    HStack(spacing: 16) {
                        Image(systemName: model.launchChoiceIndex == index ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(model.launchChoiceIndex == index ? Design.accent : Design.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title).font(Design.body(26, weight: "Medium")).lineLimit(2)
                            if option.title != option.spec.executableRelativePath {
                                Text(option.spec.executableRelativePath).font(Design.body(20)).foregroundStyle(Design.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }.font(Design.body(26)).padding(18).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        .background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .focusRing(model.panelIndex == index)
                }.buttonStyle(.plain).id(index)
            }
        }.padding(10)
    }

}
