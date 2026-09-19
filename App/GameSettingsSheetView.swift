import SwiftUI
import Domain
import Focus

/// Board 4a/4b. Right-anchored sheet listing the game's runtime profile and settings, grouped into
/// always-visible sections, with a fixed footer for the legend and reset.
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
    }

    // MARK: - Scrolling list

    private var listViewport: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(settingsListLayout(for: gameID).items.enumerated()), id: \.offset) { _, item in
                    listEntryView(item.entry)
                }
            }
            // The top inset keeps the focus ring's glow inside the viewport on the first row; the bottom
            // inset adds the fade height so the last row can scroll clear of it. `settingsListLayout` bakes in both.
            .padding(.top, Self.topInset).padding(.bottom, Self.bottomInset)
            .padding(.horizontal, Self.sideInset)
            .frame(width: geo.size.width, alignment: .topLeading)
            .offset(y: -model.settingsScrollOffset)
            .onAppear { listViewportHeight = geo.size.height; revealSettingsFocus() }
            .onChange(of: geo.size.height) { _, newValue in listViewportHeight = newValue; revealSettingsFocus() }
        }
        .clipped()
        // Let the focus ring bleed past the rows' horizontal edges without leaving the clip region.
        .padding(.horizontal, -Self.sideInset)
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
                content: layout.contentHeight, margin: 130)
        }
    }

    // MARK: - Layout

    private static let topInset = 28.0, bottomInset = 148.0, sideInset = 16.0, rowGap = 12.0, rowHeight = 124.0
    private enum SettingsListEntry { case header(String), row(GameSettingsRow, index: Int) }
    private struct SettingsListItem { let entry: SettingsListEntry; let top: Double; let height: Double }

    /// Fixed row heights so the scroll math in `revealSettingsFocus` lines up exactly with what's drawn:
    /// `rowHeight` for the profile and setting rows, 52 for section headers.
    private func settingsListLayout(for gameID: GameID) -> (items: [SettingsListItem], contentHeight: Double) {
        var items: [SettingsListItem] = []
        var y = Self.topInset
        var section: RuntimeSettingSection?
        func place(_ entry: SettingsListEntry, height: Double) {
            if !items.isEmpty { y += Self.rowGap }
            items.append(SettingsListItem(entry: entry, top: y, height: height))
            y += height
        }
        for (index, row) in model.settingsRows(for: gameID).enumerated() {
            switch row {
            case .profile:
                place(.row(row, index: index), height: Self.rowHeight)
            case .setting(let id):
                let rowSection = GameSettingsCatalog.definition(id).section
                if section != rowSection {
                    place(.header(rowSection.title), height: 52)
                    section = rowSection
                }
                place(.row(row, index: index), height: Self.rowHeight)
            case .resetAll:
                break // rendered in the fixed footer, not the scrolling list
            }
        }
        return (items, y + Self.bottomInset)
    }

    @ViewBuilder
    private func listEntryView(_ entry: SettingsListEntry) -> some View {
        switch entry {
        case .header(let title): sectionHeader(title)
        case .row(let row, let index):
            settingsRow(row, index: index)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased()).font(Design.condensed(20)).tracking(2.4).foregroundStyle(Design.secondary)
            .padding(.top, 22).padding(.horizontal, 24).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 52)
    }

    // MARK: - Setting / profile rows

    private func settingsRow(_ row: GameSettingsRow, index: Int) -> some View {
        let focused = model.settingsFocus == index
        return Button {
            model.settingsFocus = index
            model.perform(.confirm)
        } label: {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    nameLine(row)
                    Text(effect(for: row)).font(Design.body(19)).lineSpacing(3)
                        .foregroundStyle(Color(hex: 0xD6D0C8))
                        .fixedSize(horizontal: false, vertical: true).lineLimit(2)
                    alsoCalledLine(row)
                }.frame(maxWidth: .infinity, alignment: .leading)
                valueGroup(row)
            }
            .padding(.vertical, 18).padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading).frame(height: Self.rowHeight)
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
        Text(alsoCalled(for: row)).font(Design.body(16)).foregroundStyle(Design.muted).lineLimit(1)
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
        case .resetAll: ""
        }
    }
    private func effect(for row: GameSettingsRow) -> String {
        switch row {
        case .profile: GameSettingsCatalog.profileEffect
        case .setting(let id): GameSettingsCatalog.definition(id).effect
        case .resetAll: ""
        }
    }
    private func alsoCalled(for row: GameSettingsRow) -> String {
        switch row {
        case .profile: GameSettingsCatalog.profileAlsoCalled
        case .setting(let id): GameSettingsCatalog.definition(id).alsoCalled
        case .resetAll: ""
        }
    }
    private func value(for row: GameSettingsRow) -> String {
        switch row {
        case .profile: model.profileLabel(gameID)
        case .setting(let id): model.rowValueLabel(gameID, id)
        case .resetAll: ""
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 30) {
                LegendItem(glyph: keyboard ? "↵" : model.controllerConfirmGlyph, title: "Change")
                LegendItem(glyph: keyboard ? "ESC" : model.controllerBackGlyph, title: "Close")
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
