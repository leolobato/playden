import SwiftUI
import Domain

struct GameSettingPicker: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    let setting: RuntimeSettingID

    private var definition: RuntimeSettingDefinition { GameSettingsCatalog.definition(setting) }
    private var choices: [RuntimeSettingChoice] { model.pickerChoices(gameID, setting) }
    private var resolved: RuntimeSettingValue? { model.resolvedValues(gameID).resolved[setting] }
    private var baseValueLabel: String {
        GameSettingsCatalog.valueLabel(setting, value: model.resolvedValues(gameID).base[setting], launchOptions: model.gameLaunchOptions[gameID] ?? [])
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            GameSettingsSheet(model: model, gameID: gameID)
                .offset(x: -60).brightness(-0.4).allowsHitTesting(false)
            pickerSheet
        }
    }

    private var pickerSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            choicesList
            Text("Profile \u{201C}\(model.profileName(gameID))\u{201D} sets \(baseValueLabel). Choosing another value turns the profile into Custom. Applies on next launch.")
                .font(Design.body(18)).foregroundStyle(Design.muted).lineSpacing(4)
                .padding(.top, 20)
            Spacer(minLength: 24)
            footer
        }
        .padding(.horizontal, 60).padding(.top, 54).padding(.bottom, 54)
        .frame(width: 960, height: 1080, alignment: .topLeading)
        .background(Color(hex: 0x1A1813))
        .overlay(alignment: .leading) { Rectangle().fill(Design.text.opacity(0.1)).frame(width: 1) }
        .shadow(color: .black.opacity(0.5), radius: 40, x: -20)
        .transition(model.reducedMotion ? .identity : .move(edge: .trailing))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { model.perform(.back) } label: {
                HStack(spacing: 10) {
                    ButtonSymbol(text: "○", size: 20)
                    Text("Game settings").font(Design.body(20)).foregroundStyle(Design.secondary)
                }
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text(definition.title).font(Design.condensed(44)).foregroundStyle(Design.text)
                    if definition.changesBottle { changesBottleTag }
                }
                Text(definition.effect).font(Design.body(22)).lineSpacing(6).foregroundStyle(Color(hex: 0xD6D0C8))
                HStack(spacing: 6) {
                    Text("Also called").font(Design.body(17)).foregroundStyle(Design.secondary)
                    Text(definition.alsoCalled).font(Design.body(17)).foregroundStyle(Design.muted)
                }
            }
        }.padding(.bottom, 32)
    }

    private var changesBottleTag: some View {
        Text("Changes bottle").font(Design.body(13, weight: "SemiBold")).textCase(.uppercase).tracking(1)
            .foregroundStyle(Design.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Design.secondary.opacity(0.25), lineWidth: 1))
    }

    /// Most catalog settings have ≤ 4 choices, which fit without scrolling (per the 4c spec) and use a
    /// plain `VStack`, since `ScrollView` renders blank under the offscreen `ImageRenderer` snapshot path
    /// (`PlaydenApp.swift`'s `--snapshot-offscreen`, also affecting `PanelActionList`'s list and
    /// `GameSettingsSheet`'s `listViewport`) — this keeps `picker-graphics` capturing real content.
    /// `.launchOption` pickers can have many entries, so those scroll with focus (pattern: `PanelActionList`,
    /// `App/EditingViews.swift:4-33`).
    @ViewBuilder private var choicesList: some View {
        if choices.count > 4 {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                            choiceRow(index, choice).id(index)
                        }
                    }
                }.frame(maxHeight: 560)
                    .onAppear { proxy.scrollTo(model.pickerIndex, anchor: .center) }
                    .onChange(of: model.pickerIndex) { _, index in
                        withAnimation(model.reducedMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(index, anchor: .center) }
                    }
            }
        } else {
            VStack(spacing: 6) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    choiceRow(index, choice).id(index)
                }
            }
        }
    }

    private func choiceRow(_ index: Int, _ choice: RuntimeSettingChoice) -> some View {
        let focused = model.pickerIndex == index
        let selected: Bool = {
            guard case .scalar(let raw)? = resolved else { return false }
            return choice.value == raw
        }()
        return Button {
            model.pickerIndex = index
            model.perform(.confirm)
        } label: {
            HStack(alignment: .top, spacing: 24) {
                ZStack {
                    if selected {
                        Circle().fill(Design.accent)
                        Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(Color(hex: 0x1A1210))
                    } else {
                        Circle().stroke(Design.text.opacity(0.3), lineWidth: 2)
                    }
                }.frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(choice.name).font(Design.condensed(30)).foregroundStyle(Design.text)
                        if let tag = choice.tag {
                            Text(tag).font(Design.body(16, weight: "Medium")).foregroundStyle(choice.tagIsWarning ? Design.amber : Design.secondary)
                        }
                    }
                    Text(choice.explanation).font(Design.body(20)).lineSpacing(5).foregroundStyle(Color(hex: 0xD6D0C8))
                        .fixedSize(horizontal: false, vertical: true)
                    if !choice.technicalNames.isEmpty {
                        Text(choice.technicalNames).font(Design.body(16)).foregroundStyle(Design.muted)
                    }
                }
                Spacer(minLength: 12)
                if let meta = model.pickerMeta(gameID, setting, choice: choice) {
                    Text(meta).font(Design.body(17)).foregroundStyle(Design.muted)
                }
            }
            .padding(.vertical, 22).padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.text.opacity(focused ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 8))
            .focusRing(focused)
        }.buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 32) {
            LegendItem(glyph: "✕", title: "Select")
            LegendItem(glyph: "○", title: "Back")
            LegendItem(glyph: "△", title: "Reset to profile")
        }
    }
}
