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
                VStack(alignment: .leading, spacing: 14) {
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
                }.offset(y: 24 + Double(index) * 442 - model.homeScrollOffset)
            }
        }.frame(width: 1848, height: 894, alignment: .topLeading).clipped()
            .animation(model.reducedMotion ? nil : .easeOut(duration: 0.18), value: model.homeScrollOffset)
    }
}
