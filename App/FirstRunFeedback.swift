import SwiftUI
import Domain

extension LibraryModel {
    func queueFirstRunFeedback(for played: PlaySessionRecord) {
        // A setup/sign-in/cloud failure isn't a play session. A runtime that failed before
        // showing a window is eligible, so the player can report that the game didn't run.
        guard played.endedAt != nil, played.runtime != nil, !launcherQuitting,
              games.contains(where: { $0.id == played.gameID }),
              !firstRunFeedbackShown.contains(played.gameID) else { return }
        do {
            guard try catalog?.isFirstRuntimeSession(played) ?? true else { return }
            pendingFirstRunFeedback = played.gameID
            presentFirstRunFeedbackIfReady()
        } catch {
            // Keep launch/session recovery available if the history cannot be read.
            persistenceError = error.localizedDescription
        }
    }

    func presentFirstRunFeedbackIfReady() {
        guard let id = pendingFirstRunFeedback, !hasActiveSession, panel == nil,
              !launcherQuitting, !resetBusy, !uninstallBusy, authScreen == nil, setupScreen == nil else { return }
        guard !firstRunFeedbackShown.contains(id) else { pendingFirstRunFeedback = nil; return }
        do {
            try updateSetupPreferences { preferences in
                var shown = preferences.firstRunFeedbackShown ?? []
                if !shown.contains(id) { shown.append(id) }
                preferences.firstRunFeedbackShown = shown
            }
            firstRunFeedbackShown.insert(id)
            pendingFirstRunFeedback = nil; firstRunRating = nil
            show(.firstRunFeedback(id))
        } catch {
            pendingFirstRunFeedback = nil
            persistenceError = error.localizedDescription
            show(.persistenceFailure)
        }
    }

    func activateFirstRunFeedback(_ id: GameID) {
        if let rating = [Compatibility.works, .playable, .broken][safe: panelIndex] {
            guard let index = games.firstIndex(where: { $0.id == id }) else { return }
            games[index].compatibility = rating
            guard panel == .firstRunFeedback(id) else { return } // Persistence errors keep their recovery UI.
            firstRunRating = rating
            panelIndex = rating == .works ? 4 : 3
        } else if panelIndex == 3 {
            showGameSettings(id)
        } else { panel = nil }
    }
}

struct FirstRunFeedbackDialog: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    private let choices: [(String, String, String, Compatibility)] = [
        ("Ran well", "Everything worked as expected", "checkmark.circle", .works),
        ("Had issues", "Playable, but something needs adjusting", "wrench.and.screwdriver", .playable),
        ("Didn’t run", "Couldn’t get into the game", "exclamationmark.circle", .broken)
    ]
    private var guidance: String {
        switch model.firstRunRating {
        case .works: "Glad it worked. You can change your rating later from the game’s menu."
        case .playable, .broken: "Try adjusting graphics, display, or compatibility options in Game settings before your next launch."
        default: "Your feedback updates this game’s compatibility rating in your library."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("How did it run?").font(Design.condensed(48))
            Text(model.gameName(gameID)).font(Design.body(28)).foregroundStyle(Design.secondary)
            VStack(spacing: 12) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    Button {
                        model.panelIndex = index; model.activateFirstRunFeedback(gameID)
                    } label: {
                        HStack(spacing: 20) {
                            Image(systemName: choice.2).font(.system(size: 28)).frame(width: 36)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(choice.0).font(Design.condensed(30))
                                Text(choice.1).font(Design.body(22)).foregroundStyle(Design.secondary)
                            }
                            Spacer()
                            if model.firstRunRating == choice.3 { Image(systemName: "checkmark").foregroundStyle(Design.accent) }
                        }.foregroundStyle(Design.text).padding(22)
                            .background(Design.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).focusRing(model.panelIndex == index, compact: true)
                        .accessibilityValue(model.firstRunRating == choice.3 ? "Selected" : "Not selected")
                }
            }
            Text(guidance).font(Design.body(23)).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                ActionButton(title: "Game settings", primary: model.firstRunRating != .works, focused: model.panelIndex == 3, reducedMotion: model.reducedMotion) {
                    model.panelIndex = 3; model.activateFirstRunFeedback(gameID)
                }
                ActionButton(title: model.firstRunRating == nil ? "Not now" : "Done", primary: model.firstRunRating == .works, focused: model.panelIndex == 4, reducedMotion: model.reducedMotion) {
                    model.panelIndex = 4; model.activateFirstRunFeedback(gameID)
                }
            }
            LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "ESC" : model.controllerBackGlyph, title: "Close")
        }.padding(40).frame(width: 960)
            .background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.7), radius: 50, y: 40)
    }
}
