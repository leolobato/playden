import SwiftUI
import Domain
import Focus

/// The focus engine owns scrolling. There is no independent native scroll offset to get stuck
/// after a scaled scrollTo, a trigger page jump, or a change to the filter's contents.
struct FocusedLibraryGrid: View {
    @Bindable var model: LibraryModel
    var body: some View {
        let games = model.filteredGames
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.libraryVisibleIndices), id: \.self) { index in
                if let game = games[safe: index] {
                    GameTile(game: game, focused: model.libraryCursor.index == index && !model.railFocused,
                             reducedMotion: model.reducedMotion, paused: model.downloadPaused)
                        .offset(x: 24 + Double(index % 6) * 234,
                                y: 24 + Double(index / 6) * 339 - model.libraryScrollOffset)
                        .zIndex(model.libraryCursor.index == index ? 1 : 0)
                        .onTapGesture { model.libraryCursor = GridCursor(index: index); model.openGame(game) }
                }
            }
        }.frame(width: 1428, height: model.libraryViewportHeight + 54, alignment: .topLeading)
            .clipped()
            .animation(model.reducedMotion ? nil : .easeOut(duration: 0.18), value: model.libraryScrollOffset)
    }
}

struct FocusedHomeRows: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: 28) {
                    SectionLabel(text: row.name).padding(.leading, 24)
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(Array(row.games.enumerated()), id: \.element.id) { column, game in
                            GameTile(game: game, focused: model.homeRow == index && model.homeColumns[index, default: 0] == column,
                                     home: true, reducedMotion: model.reducedMotion,
                                     subtitle: index == 0 && column == 0 ? "31 h played · yesterday" : nil, paused: model.downloadPaused)
                                .onTapGesture { model.homeRow = index; model.homeColumns[index] = column; model.openGame(game) }
                        }
                    }.padding(.horizontal, 24).offset(x: -model.homeRowOffsets[index, default: 0])
                        .animation(model.reducedMotion ? nil : .easeOut(duration: 0.18), value: model.homeRowOffsets[index])
                }.offset(y: 24 + Double(index) * 456 - model.homeScrollOffset)
            }
        }.frame(width: 1848, height: 894, alignment: .topLeading).clipped()
            .animation(model.reducedMotion ? nil : .easeOut(duration: 0.18), value: model.homeScrollOffset)
    }
}

struct LibraryRail: View {
    @Bindable var model: LibraryModel
    var body: some View {
        let filters = model.libraryFilters
        let items = filters.map { model.filterTitle($0) } + ["＋ New collection"]
        let offset = max(0, Double(model.libraryRailIndex - 9) * 66)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Design.text.opacity(0.12)).frame(width: 256, height: 1).offset(x: 46, y: 303 - offset)
            ForEach(Array(items.enumerated()), id: \.offset) { index, title in
                Button {
                    model.libraryRailIndex = index
                    if let value = filters[safe: index] { model.filter = value; model.railFocused = false }
                    else { model.beginText(.newCollection(nil)) }
                } label: {
                    HStack {
                        Text(title).font(Design.condensed(28, bold: filters[safe: index] == model.filter)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let filter = filters[safe: index] { Text(String(model.count(for: filter))).font(Design.body(20)).foregroundStyle(Design.muted) }
                    }.padding(.horizontal, 22).frame(width: 300, height: 60)
                        .foregroundStyle(filters[safe: index] == model.filter ? Design.text : Design.secondary)
                        .background(filters[safe: index] == model.filter ? Design.text.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .focusRing(model.railFocused && model.libraryRailIndex == index, compact: true)
                }.buttonStyle(.plain).offset(x: 24, y: 24 + Double(index) * 66 + (index >= 4 ? 40 : 0) - offset)
            }
        }.frame(width: 348, height: 840, alignment: .topLeading).clipped()
            .animation(model.reducedMotion ? nil : .easeOut(duration: 0.18), value: offset)
    }
}
