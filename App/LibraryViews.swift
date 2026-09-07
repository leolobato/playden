import SwiftUI
import Domain
import Focus

struct LauncherView: View {
    @Bindable var model: LibraryModel
    var body: some View {
        GeometryReader { g in
            let scale = min(g.size.width / 1920, g.size.height / 1080)
            CanvasView(model: model)
                .frame(width: 1920, height: 1080)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: 1920 * scale, height: 1080 * scale, alignment: .topLeading)
                .frame(width: g.size.width, height: g.size.height)
        }.background(Design.background).preferredColorScheme(.dark)
    }
}

struct CanvasView: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            Design.background
            if model.detailID != nil, let game = model.focusedGame {
                GamePage(model: model, game: game)
            } else {
                Group {
                    switch model.tab {
                    case .home: HomeScreen(model: model)
                    case .library: LibraryScreen(model: model)
                    case .downloads: DownloadsScreen(model: model)
                    case .settings: SettingsScreen(model: model)
                    }
                }
                TopBar(model: model).frame(width: 1728, height: 56).offset(x: 96, y: 54)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Design.background, location: 0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 150).offset(y: 930).allowsHitTesting(false)
            BottomBar(model: model).frame(width: 1728, height: 40).offset(x: 96, y: 986)
            if model.panel != nil { ModalLayer(model: model) }
        }.frame(width: 1920, height: 1080).clipped().foregroundStyle(Design.text)
            .environment(\.colorScheme, .dark)
    }
}
struct TopBar: View {
    @Bindable var model: LibraryModel
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Button { model.selectTab(tab) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.symbol).font(.system(size: 26, weight: .regular))
                            Text(tab.rawValue).font(Design.condensed(30, bold: model.tab == tab))
                            if tab == .downloads { Text("1").font(Design.body(16, weight: "SemiBold")).foregroundStyle(Design.background).padding(.horizontal, 8).padding(.vertical, 5).background(Design.accent, in: Capsule()) }
                        }.padding(.horizontal, 22).frame(height: 52)
                            .foregroundStyle(model.tab == tab ? Design.text : Design.secondary)
                            .background(model.tab == tab ? Design.text.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.tab == tab ? Design.text.opacity(0.35) : .clear, lineWidth: 2))
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            HStack(spacing: 22) {
                HStack(spacing: 12) {
                    Circle().fill(LinearGradient(colors: [Design.accent, Color(hex: 0x8A3D15)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 40, height: 40)
                    Text("Preview").font(Design.body(24, weight: "Medium"))
                }
                ClockLabel(fixed: model.fixedClock)
            }
        }
    }
}
struct ClockLabel: View {
    var fixed: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(fixed ? "21:42" : context.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                .font(Design.condensed(26, bold: false)).foregroundStyle(Design.secondary)
        }
    }
}
struct BottomBar: View {
    @Bindable var model: LibraryModel
    var body: some View {
        HStack(spacing: 30) {
            LegendItem(glyph: model.playStationGlyphs ? "✕" : "A", title: model.detailID != nil ? "Select" : model.tab == .downloads ? (model.downloadPaused ? "Resume" : "Pause") : "Open")
            if model.detailID != nil || model.tab == .library { LegendItem(glyph: model.playStationGlyphs ? "○" : "B", title: "Back") }
            if model.tab != .settings { LegendItem(glyph: model.playStationGlyphs ? "△" : "Y", title: "More") }
            if model.detailID == nil && model.tab == .home { LegendItem(glyph: model.playStationGlyphs ? "□" : "X", title: "Favorite") }
            if model.detailID == nil {
                if model.tab == .library { LegendItem(glyph: model.playStationGlyphs ? "OPTIONS" : "MENU", title: "Sort & filter") }
                else { HStack(spacing: 10) { Glyph(text: model.playStationGlyphs ? "L1" : "LB"); Glyph(text: model.playStationGlyphs ? "R1" : "RB"); Text("Tabs").font(Design.body(22, weight: "Medium")) } }
                if model.tab == .home || model.tab == .library { LegendItem(glyph: model.playStationGlyphs ? "PAD" : "VIEW", title: "Search") }
            }
            Spacer(minLength: 0)
            if model.detailID == nil && model.tab != .downloads && model.tab != .settings {
                HStack(spacing: 16) {
                    Image(systemName: model.downloadPaused ? "pause.fill" : "arrow.down.to.line").foregroundStyle(Design.accent)
                    Text("TUNIC").font(Design.body(20, weight: "SemiBold"))
                    ProgressTrack(value: 0.43, height: 6).frame(width: 120)
                    Text(model.downloadPaused ? "Paused" : "43% · 38 MB/s").font(Design.body(20, weight: "SemiBold")).foregroundStyle(Design.secondary)
                }.padding(.horizontal, 16).frame(height: 40).background(Design.text.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct HomeScreen: View {
    @Bindable var model: LibraryModel
    @State private var ambientURL: URL?
    var body: some View {
        ZStack(alignment: .topLeading) {
            Artwork(url: ambientURL).blur(radius: 90).opacity(0.22).frame(width: 1920, height: 1080)
            LinearGradient(colors: [.clear, Design.background.opacity(0.6), Design.background], startPoint: .top, endPoint: .bottom)
            if model.rows.isEmpty {
                VStack(spacing: 28) {
                    Text("Your next adventure starts here").font(Design.condensed(56))
                    Text("Find a game in your library and make yourself at home.").font(Design.body(26)).foregroundStyle(Design.secondary)
                    ActionButton(title: "Browse library", primary: true, focused: true, reducedMotion: model.reducedMotion) { model.browseAvailableGames() }
                }.frame(width: 1920, height: 1080)
            }
            ScrollViewReader { vertical in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                            VStack(alignment: .leading, spacing: 14) {
                                SectionLabel(text: row.name).padding(.leading, 24)
                                ScrollViewReader { horizontal in
                                    ScrollView(.horizontal) {
                                        HStack(alignment: .top, spacing: 20) {
                                            ForEach(Array(row.games.enumerated()), id: \.element.id) { column, game in
                                                GameTile(game: game, focused: model.homeRow == index && model.homeColumns[index, default: 0] == column,
                                                         home: true, reducedMotion: model.reducedMotion,
                                                         subtitle: index == 0 && column == 0 ? "31 h played · yesterday" : nil, paused: model.downloadPaused)
                                                    .id(column).onTapGesture { model.homeRow = index; model.homeColumns[index] = column; model.openGame(game) }
                                            }
                                        }.padding(.horizontal, 24)
                                    }.scrollIndicators(.hidden).scrollClipDisabled().frame(height: 400)
                                        .onChange(of: model.homeColumns[index, default: 0]) { _, column in
                                            withAnimation(model.reducedMotion ? nil : .easeOut(duration: 0.18)) { horizontal.scrollTo(column) }
                                        }
                                }
                            }.id(index)
                        }
                    }.padding(.top, 24).padding(.bottom, 140)
                }.scrollIndicators(.hidden).scrollClipDisabled()
                    .onChange(of: model.homeRow) { _, row in withAnimation(model.reducedMotion ? nil : .easeOut(duration: 0.18)) { vertical.scrollTo(row, anchor: .top) } }
            }.frame(width: 1848, height: 860).offset(x: 72, y: 126)
        }.task(id: model.focusedGame?.heroURL) {
            let url = model.focusedGame?.heroURL
            if ambientURL != nil && !model.reducedMotion { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            withAnimation(model.reducedMotion ? nil : .easeOut(duration: 0.25)) { ambientURL = url }
        }
    }
}

struct LibraryScreen: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 6) {
                ForEach(Array(LibraryFilter.allCases.enumerated()), id: \.element) { index, value in
                    if index == 4 { Rectangle().fill(Design.text.opacity(0.12)).frame(height: 1).padding(.horizontal, 22).padding(.vertical, 18) }
                    Button { model.filter = value; model.libraryCursor = .init(); model.railFocused = false } label: {
                        HStack {
                            Text(value.rawValue).font(Design.condensed(28, bold: model.filter == value))
                            Spacer()
                            Text(count(value)).font(Design.body(20)).foregroundStyle(Design.muted)
                        }.padding(.horizontal, 22).frame(height: 60)
                            .foregroundStyle(model.filter == value ? Design.text : Design.secondary)
                            .background(model.filter == value ? Design.text.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .focusRing(model.railFocused && model.filter == value, compact: true)
                    }.buttonStyle(.plain)
                }
            }.frame(width: 300).offset(x: 96, y: 150)
            if !model.query.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(Design.secondary)
                    Text(model.query).font(Design.body(30, weight: "Medium"))
                    Spacer()
                    Text("\(model.filteredGames.count) results").font(Design.body(24)).foregroundStyle(Design.secondary)
                }.padding(.horizontal, 22).frame(width: 1380, height: 64).background(Design.text.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).offset(x: 444, y: 150)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(210), spacing: 24, alignment: .top), count: 6), spacing: 24) {
                        ForEach(Array(model.filteredGames.enumerated()), id: \.element.id) { index, game in
                            GameTile(game: game, focused: model.libraryCursor.index == index && !model.railFocused, reducedMotion: model.reducedMotion, paused: model.downloadPaused)
                                .id(index).zIndex(model.libraryCursor.index == index ? 1 : 0)
                                .onTapGesture { model.libraryCursor = GridCursor(index: index); model.openGame(game) }
                        }
                    }.padding(24).padding(.bottom, 100)
                }.scrollIndicators(.hidden).scrollClipDisabled()
                    .onChange(of: model.libraryCursor.index) { _, index in
                        withAnimation(model.reducedMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(index) }
                    }
                    .onChange(of: model.filter) { _, _ in proxy.scrollTo(0, anchor: .top) }
            }.frame(width: 1428, height: model.query.isEmpty ? 870 : 780).offset(x: 420, y: model.query.isEmpty ? 126 : 216)
            if model.filteredGames.isEmpty {
                VStack(spacing: 24) {
                    Text(model.query.isEmpty ? "Nothing here yet" : "No games match ‘\(model.query)’").font(Design.condensed(56))
                    Text("Try another collection or clear your search.").font(Design.body(26)).foregroundStyle(Design.secondary)
                    ActionButton(title: "Browse all games", primary: true, focused: !model.railFocused) { model.browseAvailableGames() }
                }.frame(width: 1380, height: 650).offset(x: 444, y: 150)
            }
        }
    }
    private func count(_ filter: LibraryFilter) -> String {
        String(model.games.filter { game in
            if filter == .hidden { return game.isHidden }
            guard !game.isHidden else { return false }
            return switch filter { case .all: true; case .installed: [.installed,.driveDisconnected].contains(game.status); case .favorites: game.isFavorite; case .coop: game.genres.contains("Couch co-op"); case .short: game.hoursPlayed > 0 && game.hoursPlayed < 8; case .hidden: false }
        }.count)
    }
}

struct GamePage: View {
    @Bindable var model: LibraryModel
    let game: Game
    var body: some View {
        ZStack(alignment: .topLeading) {
            Artwork(url: game.heroURL).frame(width: 1920, height: 620)
            LinearGradient(stops: [.init(color: Design.background.opacity(0.4), location: 0), .init(color: .clear, location: 0.3), .init(color: .clear, location: 0.75), .init(color: Design.background, location: 1)], startPoint: .top, endPoint: .bottom).frame(height: 620)
            HStack { LegendItem(glyph: model.playStationGlyphs ? "○" : "B", title: model.tab.rawValue); Spacer(); ClockLabel(fixed: model.fixedClock) }.frame(width: 1728, height: 40).offset(x: 96, y: 54)
            Artwork(url: game.logoURL, title: game.title, fit: true, transparent: true).frame(width: 460, height: 160).shadow(color: .black.opacity(0.5), radius: 20, y: 8).offset(x: 96, y: 430)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(Array(model.detailActions.enumerated()), id: \.offset) { index, title in
                            ActionButton(title: index == 1 ? (game.isFavorite ? "♥" : "□") : title == "Play" ? "▶  Play" : title,
                                         primary: index == 0, detail: title == "Install" ? game.size : nil, focused: model.detailAction == index, large: index == 0, reducedMotion: model.reducedMotion) {
                                model.detailAction = index; model.activateDetail()
                            }.id(index)
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 18)
                }.scrollIndicators(.hidden).scrollClipDisabled()
                    .onChange(of: model.detailAction) { _, index in withAnimation(model.reducedMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(index) } }
            }.frame(width: 1776, height: 120).offset(x: 72, y: 622)
            HStack(alignment: .top, spacing: 80) {
                VStack(alignment: .leading, spacing: 24) {
                    Text(game.summary).font(Design.body(26)).foregroundStyle(Color(hex: 0xD6D0C8)).lineSpacing(7).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        ForEach(game.genres, id: \.self) { tag in Text(tag).font(Design.body(20, weight: "Medium")).padding(.horizontal, 16).padding(.vertical, 8).background(Design.text.opacity(0.1), in: RoundedRectangle(cornerRadius: 6)) }
                    }
                }.frame(width: 1128, alignment: .leading)
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 40) { metadata("Playtime", game.hoursPlayed == 0 ? "Never played" : "\(game.hoursPlayed) hours"); metadata(game.status == .installed ? "Size" : "Download", game.size) }
                    HStack(alignment: .top, spacing: 40) { metadata("Source", "Steam"); metadata("Compatibility", game.compatibility.rawValue) }
                    metadata("Controller", "Full support")
                    if game.status == .installed { HStack(spacing: 8) { Circle().fill(Design.green).frame(width: 8, height: 8); Text("Last session ended cleanly").font(Design.body(18)).foregroundStyle(Design.secondary) } }
                }.frame(width: 520)
            }.offset(x: 96, y: 754)
        }
    }
    private func metadata(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(Design.condensed(16)).tracking(1.6).foregroundStyle(Design.secondary)
            Text(value).font(Design.body(26, weight: "Medium"))
        }.frame(width: 240, alignment: .leading)
    }
}
