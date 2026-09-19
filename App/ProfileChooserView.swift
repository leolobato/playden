import SwiftUI
import Domain

/// Board 4d. Full-screen chooser: curated profiles on the left, a comparison table for the
/// focused profile (or the current Custom summary) on the right.
struct ProfileChooser: View {
    @Bindable var model: LibraryModel
    let gameID: GameID

    private var game: Game? { model.games.first { $0.id == gameID } }
    private var rows: [CuratedProfile?] { model.chooserRows(gameID) }
    /// Double optional: outer nil means out of range, inner nil means the trailing Custom row.
    private var focusedEntry: CuratedProfile?? { rows[safe: model.chooserIndex] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Design.background
            AmbientBackdrop(url: game?.heroURL, reducedMotion: model.reducedMotion)
            breadcrumb
            gameTitle
            titleBlock
            list
            detail
            legend
        }
        .frame(width: 1920, height: 1080)
        .foregroundStyle(Design.text)
        .transition(model.reducedMotion ? .identity : .opacity)
    }

    private var breadcrumb: some View {
        Button { model.perform(.back) } label: {
            HStack(spacing: 10) {
                ButtonSymbol(text: model.controllerBackGlyph, size: 20)
                Text("Game settings").font(Design.body(24)).foregroundStyle(Design.secondary)
            }
        }.buttonStyle(.plain).offset(x: 96, y: 60)
    }

    private var gameTitle: some View {
        Text(model.gameName(gameID)).font(Design.body(22)).foregroundStyle(Design.secondary)
            .frame(width: 1824, alignment: .trailing).offset(y: 60)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a profile").font(Design.condensed(56)).foregroundStyle(Design.text)
            Text("A profile sets several settings at once. You can still change any of them afterwards.")
                .font(Design.body(24)).foregroundStyle(Design.secondary)
        }.offset(x: 96, y: 130)
    }

    // MARK: - Left list

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                listRow(row, index: index)
            }
        }.frame(width: 640, alignment: .leading).offset(x: 96, y: 270)
    }

    private func listRow(_ row: CuratedProfile?, index: Int) -> some View {
        let focused = model.chooserIndex == index
        let current = isCurrent(row)
        return Button {
            model.chooserIndex = index
            model.perform(.confirm)
        } label: {
            HStack(spacing: 12) {
                Text(row?.name ?? "Custom").font(Design.condensed(28))
                    .foregroundStyle(row == nil ? Design.secondary : Design.text)
                if current { currentTag }
                Spacer()
                Text(row?.shortHint ?? "Your current changes").font(Design.body(18)).foregroundStyle(Design.muted)
            }
            .padding(.vertical, 16).padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.text.opacity(focused ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 8))
            .focusRing(focused)
        }.buttonStyle(.plain)
    }

    private var currentTag: some View {
        Text("Current").font(Design.body(13, weight: "SemiBold")).textCase(.uppercase).tracking(1)
            .foregroundStyle(Design.text.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Design.text.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    private func isCurrent(_ row: CuratedProfile?) -> Bool {
        let profile = model.profile(for: gameID)
        guard let curated = row else { return profile.isCustom }
        return !profile.isCustom && curated.id == (profile.base ?? CuratedProfileCatalog.playdenDefaultID)
    }

    // MARK: - Right panel

    private var detail: some View {
        Group {
            if let entry = focusedEntry {
                if let curated = entry { curatedDetail(curated) } else { customDetail }
            }
        }
        .padding(.vertical, 34).padding(.horizontal, 40)
        .frame(width: 1004, height: 730, alignment: .topLeading)
        .background(Color(red: 22 / 255, green: 20 / 255, blue: 15 / 255).opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
        .offset(x: 820, y: 270)
    }

    private func curatedDetail(_ curated: CuratedProfile) -> some View {
        let items = model.comparison(gameID, with: curated.id)
        return VStack(alignment: .leading, spacing: 24) {
            Text(curated.name).font(Design.condensed(40)).foregroundStyle(Design.text)
            (Text("Try it when ").foregroundStyle(Design.secondary) + Text(curated.tryWhen).foregroundStyle(Design.text))
                .font(Design.body(22)).lineSpacing(6)
            VStack(alignment: .leading, spacing: 6) {
                tableHeader
                ForEach(items, id: \.id) { comparisonRow($0) }
            }
            Text(summary(items, curated: curated)).font(Design.body(18)).foregroundStyle(Design.muted)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var customDetail: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Custom").font(Design.condensed(40)).foregroundStyle(Design.text)
            Text("Your current settings, based on \(model.profileName(gameID)). Pick a profile to replace them, or go back to keep them.")
                .font(Design.body(22)).lineSpacing(6).foregroundStyle(Design.text)
            Spacer(minLength: 0)
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("Setting").frame(maxWidth: .infinity, alignment: .leading)
            Text("Current").frame(width: 200, alignment: .leading)
            Spacer().frame(width: 30)
            Text("This profile").frame(width: 200, alignment: .leading)
        }
        .font(Design.condensed(16)).textCase(.uppercase).tracking(2).foregroundStyle(Design.muted)
        .padding(.horizontal, 16)
    }

    private func comparisonRow(_ item: LibraryModel.SettingComparison) -> some View {
        HStack(spacing: 0) {
            Text(item.title).foregroundStyle(Design.text).frame(maxWidth: .infinity, alignment: .leading)
            Text(item.current).foregroundStyle(Design.muted).frame(width: 200, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 20))
                .foregroundStyle(item.changed ? Design.accent : Design.muted.opacity(0.5))
                .frame(width: 30, alignment: .leading)
            Text(item.proposed).foregroundStyle(item.changed ? Design.text : Design.muted).frame(width: 200, alignment: .leading)
        }
        .font(Design.body(22))
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(item.changed ? Design.accent.opacity(0.08) : Design.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    private func summary(_ items: [LibraryModel.SettingComparison], curated: CuratedProfile) -> String {
        let changedCount = items.filter(\.changed).count
        var text = changedCount == 0 ? "No settings change." : changedCount == 1 ? "1 setting changes." : "\(changedCount) settings change."
        if let fallbackHint = curated.fallbackHint { text += " \(fallbackHint)" }
        if items.contains(where: { $0.changed && GameSettingsCatalog.definition($0.id).changesBottle }) {
            text += " Graphics and Synchronization rewrite this game’s bottle."
        }
        return text
    }


    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 32) {
            LegendItem(glyph: model.controllerConfirmGlyph, title: "Use this profile")
            LegendItem(glyph: model.controllerBackGlyph, title: "Back")
        }.offset(x: 96, y: 1000)
    }
}
