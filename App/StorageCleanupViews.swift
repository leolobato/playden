import SwiftUI
import Domain

struct StorageCleanupSheet: View {
    @Bindable var model: LibraryModel
    private var state: StorageCleanupState { model.storageCleanup }
    private var keyboard: Bool { model.controllerName == nil || model.keyboardNavigation }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Storage").font(Design.condensed(48))
            volumes
            listHeader
            gameList
            footer
            legend
        }.padding(40).frame(width: 1500, height: 980, alignment: .top)
            .background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay { if state.confirming { confirmation } }
            .shadow(color: .black.opacity(0.7), radius: 50, y: 40)
    }

    private var volumes: some View {
        HStack(spacing: 16) {
            ForEach(model.storageVolumes) { volume in
                let selected = volume.id == model.storageVolume?.id
                VolumeUsageCard(volume: volume, gamesBytes: model.storageBytes(on: volume.id), selected: selected)
                    .focusRing(state.focus == .volumes && selected, compact: true)
                    .onTapGesture {
                        guard !state.busy, let current = model.storageVolumes.firstIndex(where: { $0.id == model.storageVolume?.id }),
                              let target = model.storageVolumes.firstIndex(of: volume) else { return }
                        model.storageCleanup.focus = .volumes; model.selectStorageVolume(offset: target - current)
                    }
            }
            if model.storageVolumes.isEmpty {
                Text(model.refreshingInstallVolumes ? "Looking for volumes…" : "No games volume is connected.")
                    .font(Design.body(24)).foregroundStyle(Design.secondary).frame(height: 132)
            }
            Spacer(minLength: 0)
        }
    }

    private var listHeader: some View {
        HStack(spacing: 12) {
            Text("Sort by").font(Design.body(22)).foregroundStyle(Design.secondary)
            HStack(spacing: 4) {
                ForEach(StorageSort.allCases, id: \.self) { sort in
                    let active = state.sort == sort
                    Text(sort.rawValue).font(Design.body(22, weight: active ? "SemiBold" : "Medium"))
                        .foregroundStyle(active ? Design.background : Design.text)
                        .padding(.horizontal, 18).frame(height: 44)
                        .background(active ? Design.accent : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .onTapGesture { guard !state.busy else { return }; model.storageCleanup.focus = .sort; model.storageCleanup.sort = sort }
                }
            }.padding(4).background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .focusRing(state.focus == .sort, compact: true)
            Spacer()
            let rows = model.storageRows
            Text(rows.isEmpty ? "" : "\(rows.count) game\(rows.count == 1 ? "" : "s") · \(size(rows.reduce(0) { $0 + $1.bytes }))")
                .font(Design.body(22)).foregroundStyle(Design.secondary)
        }
    }

    private var gameList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(model.storageRows.enumerated()), id: \.element.id) { index, row in
                        StorageGameRowView(model: model, row: row, checked: state.selection.contains(row.id), focused: state.focus == .game(index))
                            .id(index)
                            .onTapGesture {
                                guard !state.busy else { return }
                                model.storageCleanup.focus = .game(index); model.toggleStorageSelection(row.id)
                            }
                    }
                    if model.storageRows.isEmpty && !model.storageVolumes.isEmpty {
                        Text("No games installed on this volume.").font(Design.body(24)).foregroundStyle(Design.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    }
                }.padding(8)
            }.frame(maxHeight: .infinity)
                .onChange(of: state.focus) { _, focus in
                    if case .game(let index) = focus { withAnimation(model.reducedMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(index) } }
                }
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            if let progress = state.progress {
                ActivitySpinner(reducedMotion: model.reducedMotion, label: progress)
                Text(progress).font(Design.body(22)).foregroundStyle(Design.secondary).lineLimit(1)
            } else if let message = state.message {
                Text(message).font(Design.body(22)).foregroundStyle(Design.amber).lineLimit(2)
            } else {
                Text(model.storageSelectedRows.isEmpty ? "Check games to remove them from this Mac. Playtime, collections and Cloud saves are kept."
                     : "\(size(model.storageSelectedBytes)) will be freed on \(model.storageVolume?.name ?? "this volume").")
                    .font(Design.body(22)).foregroundStyle(Design.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            ActionButton(title: "Done", focused: state.focus == .done, reducedMotion: model.reducedMotion) {
                guard !state.busy else { return }
                model.panel = nil
            }
            let count = model.storageSelectedRows.count
            ActionButton(title: count == 0 ? "Delete" : "Delete \(count) game\(count == 1 ? "" : "s")", primary: count > 0,
                         focused: state.focus == .delete, reducedMotion: model.reducedMotion) {
                guard !state.busy else { return }
                model.storageCleanup.focus = .delete; model.activateStorageFocus()
            }.disabled(count == 0 || state.busy).opacity(count == 0 || state.busy ? 0.4 : 1)
        }
    }

    private var legend: some View {
        HStack(spacing: 28) {
            LegendItem(glyph: keyboard ? "↵" : model.controllerConfirmGlyph, title: "Select")
            LegendItem(glyph: keyboard ? "O" : model.playStationGlyphs ? "OPTIONS" : "MENU", title: "Sort")
            if model.storageVolumes.count > 1 {
                HStack(spacing: 10) {
                    Glyph(text: keyboard ? "SHIFT TAB" : model.playStationGlyphs ? "L1" : "LB")
                    Glyph(text: keyboard ? "TAB" : model.playStationGlyphs ? "R1" : "RB")
                    Text("Volume").font(Design.body(22, weight: "Medium"))
                }
            }
            LegendItem(glyph: keyboard ? "ESC" : model.controllerBackGlyph, title: state.busy ? "Stop" : "Close")
            Spacer()
        }.foregroundStyle(Design.secondary)
    }

    private var confirmation: some View {
        let rows = model.storageSelectedRows
        return ZStack {
            Design.background.opacity(0.6).clipShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { model.storageCleanup.confirming = false }
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 22) {
                    Image(systemName: "trash").font(.system(size: 34, weight: .light)).foregroundStyle(Design.accent)
                    Text("Delete \(rows.count) game\(rows.count == 1 ? "" : "s")?").font(Design.condensed(42))
                }
                Text(rows.prefix(4).map(\.title).joined(separator: ", ") + (rows.count > 4 ? " and \(rows.count - 4) more" : ""))
                    .font(Design.body(24)).foregroundStyle(Design.text).lineLimit(2)
                Text("Frees \(size(model.storageSelectedBytes)). Game files, runtimes and local saves are removed. Playden syncs Steam Cloud saves first and asks again about any game whose progress could not be synced.")
                    .font(Design.body(22)).foregroundStyle(Design.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    ActionButton(title: "Cancel", focused: state.confirmIndex == 0, reducedMotion: model.reducedMotion) { model.storageCleanup.confirming = false }
                    ActionButton(title: "Delete", primary: true, focused: state.confirmIndex == 1, reducedMotion: model.reducedMotion) { model.deleteSelectedStorageGames() }
                    Spacer(minLength: 0)
                }.padding(.top, 6)
            }.padding(44).frame(width: 900)
                .background(Design.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Design.text.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 60, y: 24)
        }
    }
}

private struct VolumeUsageCard: View {
    let volume: GamesVolume
    let gamesBytes: Int64
    let selected: Bool
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var body: some View {
        let total = max(1, volume.totalBytes ?? (volume.freeBytes + gamesBytes))
        let games = min(gamesBytes, total), other = max(0, total - volume.freeBytes - games)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive").font(.system(size: 24)).foregroundStyle(selected ? Design.accent : Design.secondary)
                Text(volume.name).font(Design.condensed(30)).lineLimit(1)
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Design.accent.frame(width: geometry.size.width * Double(games) / Double(total))
                    Design.text.opacity(0.4).frame(width: geometry.size.width * Double(other) / Double(total))
                    Design.text.opacity(0.12)
                }
            }.frame(height: 12).clipShape(Capsule()).accessibilityHidden(true)
            Text("\(size(gamesBytes)) games · \(size(volume.freeBytes)) free" + (volume.totalBytes.map { " of \(size($0))" } ?? ""))
                .font(Design.body(20)).foregroundStyle(Design.secondary).lineLimit(1)
        }.padding(22).frame(width: 440, height: 132, alignment: .topLeading)
            .background(Design.text.opacity(selected ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Design.accent.opacity(0.6) : .clear, lineWidth: 2))
    }
}

private struct StorageGameRowView: View {
    @Bindable var model: LibraryModel
    let row: StorageGameRow
    let checked: Bool
    let focused: Bool
    var body: some View {
        let game = model.games.first { $0.id == row.id }
        let blocked = row.blocker != nil
        HStack(spacing: 22) {
            Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: 30))
                .foregroundStyle(checked ? Design.accent : Design.secondary).frame(width: 36)
            Artwork(url: game?.coverURL, fallbackURL: game?.coverFallbackURL, placeholderID: row.id)
                .frame(width: 48, height: 72).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(Design.condensed(30)).lineLimit(1)
                if let blocker = row.blocker { Text(blocker).font(Design.body(20)).foregroundStyle(Design.amber) }
            }
            Spacer(minLength: 16)
            Text(lastPlayed).font(Design.body(22)).foregroundStyle(Design.secondary).frame(width: 220, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)).font(Design.body(24, weight: "Medium"))
                .monospacedDigit().frame(width: 150, alignment: .trailing)
        }.padding(.horizontal, 22).padding(.vertical, 10)
            .background(Design.text.opacity(checked ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 8))
            .opacity(blocked ? 0.5 : 1)
            .focusRing(focused, compact: true)
            .accessibilityValue(checked ? "Checked" : "Unchecked")
    }
    /// Omits the year for dates in the current year, like the game page.
    private var lastPlayed: String {
        guard let date = row.lastPlayedAt else { return "Never played" }
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return "Played " + (Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) ? date.formatted(format) : date.formatted(format.year()))
    }
}
