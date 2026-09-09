import SwiftUI
import Domain
import Focus

/// Board 4a/4b. Right-anchored sheet listing the game's runtime profile and settings, grouped into
/// Settings / More settings (collapsible) / Advanced, with a fixed footer for the legend and reset.
struct GameSettingsSheet: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    @State private var listViewportHeight: Double = 760

    private var keyboard: Bool { model.controllerName == nil || model.keyboardNavigation }
    private var resetAllIndex: Int { max(0, model.settingsRows(for: gameID).count - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("Game settings").font(Design.condensed(44))
                Spacer()
                Text(model.gameName(gameID)).font(Design.body(22)).foregroundStyle(Design.secondary)
            }.padding(.bottom, 32)
            listViewport
            if let error = model.gameSettingsError {
                Text(error).font(Design.body(18)).foregroundStyle(Design.red).padding(.top, 12)
            }
            footer.padding(.top, 24)
        }
        .padding(.top, 54).padding(.horizontal, 60).padding(.bottom, 54)
        .frame(width: 960, height: 1080, alignment: .topLeading)
        .background(Design.panel)
        .overlay(alignment: .leading) { Rectangle().fill(Design.text.opacity(0.1)).frame(width: 1) }
        .shadow(color: .black.opacity(0.5), radius: 40, x: -20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .transition(model.reducedMotion ? .identity : .move(edge: .trailing))
        .onChange(of: model.settingsFocus) { _, _ in revealSettingsFocus() }
        .onChange(of: model.moreSettingsExpanded) { _, _ in revealSettingsFocus() }
    }

    // MARK: - Scrolling list

    private var listViewport: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(settingsListLayout(for: gameID).items.enumerated()), id: \.offset) { _, item in
                    listEntryView(item.entry)
                }
            }
            // A 12 pt inset on both ends keeps the focus ring's outward bleed from being clipped by the
            // viewport edge when the first or last row is focused; `settingsListLayout` bakes in the same inset.
            .padding(.vertical, 12)
            .frame(width: geo.size.width, alignment: .topLeading)
            .offset(y: -model.settingsScrollOffset)
            .onAppear { listViewportHeight = geo.size.height; revealSettingsFocus() }
            .onChange(of: geo.size.height) { _, newValue in listViewportHeight = newValue; revealSettingsFocus() }
        }
        .clipped()
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, Design.panel], startPoint: .top, endPoint: .bottom)
                .frame(height: 120).allowsHitTesting(false)
        }
    }

    private func revealSettingsFocus() {
        let layout = settingsListLayout(for: gameID)
        guard let item = layout.items.first(where: {
            if case .row(_, let index) = $0.entry { return index == model.settingsFocus }
            return false
        }) else { return }
        withAnimation(model.reducedMotion ? nil : .easeOut(duration: 0.2)) {
            model.settingsScrollOffset = FocusViewport.reveal(offset: model.settingsScrollOffset,
                itemMin: item.top, itemMax: item.top + item.height, viewport: listViewportHeight,
                content: layout.contentHeight, margin: 100)
        }
    }

    // MARK: - Layout

    private enum SettingsListEntry { case header(String), row(GameSettingsRow, index: Int) }
    private struct SettingsListItem { let entry: SettingsListEntry; let top: Double; let height: Double }

    /// Fixed row heights so the scroll math in `revealSettingsFocus` lines up exactly with what's drawn:
    /// 118 for the profile and setting rows, 52 for section headers and the "More settings" row.
    private func settingsListLayout(for gameID: GameID) -> (items: [SettingsListItem], contentHeight: Double) {
        var items: [SettingsListItem] = []
        var y = 12.0
        var section: RuntimeSettingTier?
        func place(_ entry: SettingsListEntry, height: Double) {
            if !items.isEmpty { y += 6 }
            items.append(SettingsListItem(entry: entry, top: y, height: height))
            y += height
        }
        for (index, row) in model.settingsRows(for: gameID).enumerated() {
            switch row {
            case .profile:
                place(.row(row, index: index), height: 118)
            case .setting(let id):
                let tier = GameSettingsCatalog.definition(id).tier
                if tier == .tier1 && section != .tier1 { place(.header("Settings"), height: 52); section = .tier1 }
                if tier == .advanced && section != .advanced { place(.header("Advanced"), height: 52); section = .advanced }
                place(.row(row, index: index), height: 118)
            case .moreSettings:
                place(.row(row, index: index), height: 52)
                section = .tier2
            case .resetAll:
                break // rendered in the fixed footer, not the scrolling list
            }
        }
        return (items, y + 12)
    }

    @ViewBuilder
    private func listEntryView(_ entry: SettingsListEntry) -> some View {
        switch entry {
        case .header(let title): sectionHeader(title)
        case .row(let row, let index):
            if row == .moreSettings { moreSettingsRow(index: index) } else { settingsRow(row, index: index) }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased()).font(Design.condensed(20)).tracking(2.4).foregroundStyle(Design.secondary)
            .padding(.top, 22).padding(.horizontal, 24).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 52)
    }

    private func moreSettingsRow(index: Int) -> some View {
        let focused = model.settingsFocus == index
        return Button {
            model.settingsFocus = index
            model.perform(.confirm)
        } label: {
            HStack {
                Text("More settings".uppercased()).font(Design.condensed(20)).tracking(2.4).foregroundStyle(Design.secondary)
                Spacer()
                Text(model.moreSettingsExpanded ? "Expanded" : "Collapsed").font(Design.body(18)).foregroundStyle(Design.muted)
            }
            .padding(.top, 22).padding(.horizontal, 24).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 52)
            .focusRing(focused)
        }.buttonStyle(.plain)
    }

    // MARK: - Setting / profile rows

    private func settingsRow(_ row: GameSettingsRow, index: Int) -> some View {
        let focused = model.settingsFocus == index
        return Button {
            model.settingsFocus = index
            model.perform(.confirm)
        } label: {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    nameLine(row)
                    Text(effect(for: row)).font(Design.body(19)).lineSpacing(3)
                        .foregroundStyle(Color(hex: 0xD6D0C8))
                        .fixedSize(horizontal: false, vertical: true).lineLimit(2)
                    alsoCalledLine(row)
                }.frame(maxWidth: .infinity, alignment: .leading)
                valueGroup(row)
            }
            .padding(.vertical, 18).padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 118)
            .background(Design.text.opacity(focused ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 8))
            .focusRing(focused)
        }.buttonStyle(.plain)
    }

    private func nameLine(_ row: GameSettingsRow) -> some View {
        HStack(spacing: 10) {
            if case .setting(let id) = row, model.rowDiffers(gameID, id) {
                Circle().fill(Design.accent).frame(width: 10, height: 10)
            }
            Text(title(for: row)).font(Design.condensed(28))
            if case .setting(let id) = row, GameSettingsCatalog.definition(id).changesBottle {
                Text("CHANGES BOTTLE").font(Design.body(13, weight: "SemiBold")).tracking(1)
                    .foregroundStyle(Design.secondary)
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Design.secondary.opacity(0.25), lineWidth: 1))
            }
        }
    }

    private func alsoCalledLine(_ row: GameSettingsRow) -> some View {
        (Text("Also called ").foregroundStyle(Design.secondary) + Text(alsoCalled(for: row)).foregroundStyle(Design.muted))
            .font(Design.body(16))
    }

    private func valueGroup(_ row: GameSettingsRow) -> some View {
        let differs = { if case .setting(let id) = row { return model.rowDiffers(gameID, id) }; return false }()
        return HStack(spacing: 6) {
            Text(value(for: row)).font(Design.body(24, weight: "Medium")).foregroundStyle(differs ? Design.accent : Design.text).lineLimit(1)
            Text("›").font(Design.body(24)).foregroundStyle(Design.muted)
        }.layoutPriority(1)
    }

    private func title(for row: GameSettingsRow) -> String {
        switch row {
        case .profile: GameSettingsCatalog.profileTitle
        case .setting(let id): GameSettingsCatalog.definition(id).title
        case .moreSettings, .resetAll: ""
        }
    }
    private func effect(for row: GameSettingsRow) -> String {
        switch row {
        case .profile: GameSettingsCatalog.profileEffect
        case .setting(let id): GameSettingsCatalog.definition(id).effect
        case .moreSettings, .resetAll: ""
        }
    }
    private func alsoCalled(for row: GameSettingsRow) -> String {
        switch row {
        case .profile: GameSettingsCatalog.profileAlsoCalled
        case .setting(let id): GameSettingsCatalog.definition(id).alsoCalled
        case .moreSettings, .resetAll: ""
        }
    }
    private func value(for row: GameSettingsRow) -> String {
        switch row {
        case .profile: model.profileLabel(gameID)
        case .setting(let id): model.rowValueLabel(gameID, id)
        case .moreSettings, .resetAll: ""
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 30) {
                LegendItem(glyph: keyboard ? "↵" : model.playStationGlyphs ? "✕" : "A", title: "Change")
                LegendItem(glyph: keyboard ? "ESC" : model.playStationGlyphs ? "○" : "B", title: "Close")
            }
            Spacer()
            resetAllButton
        }.frame(height: 46)
    }

    private var resetAllButton: some View {
        let isCustom = model.profile(for: gameID).isCustom
        let focused = model.settingsFocus == resetAllIndex
        return Button {
            model.settingsFocus = resetAllIndex
            model.perform(.confirm)
        } label: {
            Text("Reset all to profile").font(Design.condensed(22))
                .foregroundStyle(isCustom ? Design.text : Design.muted)
                .padding(.horizontal, 20).frame(height: 46)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isCustom ? Design.text : Design.muted.opacity(0.35), lineWidth: 2))
                .focusRing(focused)
        }.buttonStyle(.plain)
    }
}
