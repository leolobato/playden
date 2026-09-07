import SwiftUI
import Domain

struct DownloadsScreen: View {
    @Bindable var model: LibraryModel
    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            VStack(alignment: .leading, spacing: 32) {
                SectionLabel(text: "Downloading now")
                if let game = model.games.first(where: { $0.title == "TUNIC" }) {
                    HStack(alignment: .top, spacing: 24) {
                        Artwork(url: game.coverURL).frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 16) {
                            Text("TUNIC").font(Design.condensed(36))
                            Text(model.downloadPaused ? "Paused · 43%" : "Download · 43%").font(Design.body(24, weight: "Medium")).foregroundStyle(Design.accent)
                            ProgressTrack(value: 0.43)
                            Text(model.downloadPaused ? "3.8 of 8.9 GB · ready to resume" : "3.8 of 8.9 GB · 38 MB/s · 2 min 14 s left").font(Design.body(22)).foregroundStyle(Design.secondary)
                            Text("Estimate › Reserve space › Download › Verify › Prepare › Ready").font(Design.body(18)).foregroundStyle(Design.muted)
                        }
                    }.padding(20).background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)).focusRing(model.downloadIndex == 0)
                        .onTapGesture { model.downloadIndex = 0; model.perform(.confirm) }
                }
                SectionLabel(text: "Queued · 1")
                if let game = model.games.first(where: { $0.title == "Celeste" }) {
                    HStack(spacing: 22) {
                        Artwork(url: game.coverURL).frame(width: 60, height: 90).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 8) { Text(game.title).font(Design.condensed(30)); Text("Queued · 1.2 GB").font(Design.body(22)).foregroundStyle(Design.secondary) }
                        Spacer(); Text("1").font(Design.condensed(30)).foregroundStyle(Design.muted)
                    }.padding(.horizontal, 20).padding(.vertical, 14).background(Design.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .focusRing(model.focusedGame?.id == game.id)
                        .onTapGesture { model.downloadIndex = model.downloadGames.firstIndex(where: { $0.id == game.id }) ?? 0; model.perform(.confirm) }
                }
                SectionLabel(text: "Recently finished")
                if let game = model.games.first(where: { $0.title == "Cuphead" }) {
                    HStack(spacing: 22) {
                        Artwork(url: game.coverURL).frame(width: 60, height: 90).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 8) { Text(game.title).font(Design.condensed(30)); HStack(spacing: 8) { Circle().fill(Design.green).frame(width: 8, height: 8); Text("Installed").font(Design.body(22)).foregroundStyle(Design.secondary) } }
                        Spacer(); Text("Today").font(Design.body(22)).foregroundStyle(Design.muted)
                    }.padding(.horizontal, 20).padding(.vertical, 14).background(Design.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .focusRing(model.focusedGame?.id == game.id)
                        .onTapGesture { model.downloadIndex = model.downloadGames.firstIndex(where: { $0.id == game.id }) ?? 0; model.perform(.confirm) }
                }
            }.frame(width: 1140)
            VStack(alignment: .leading, spacing: 28) {
                SectionLabel(text: "Games volume")
                VStack(alignment: .leading, spacing: 24) {
                    Text("VM").font(Design.condensed(36))
                    Text("412 GB free of 2 TB").font(Design.body(22)).foregroundStyle(Design.secondary)
                    GeometryReader { g in HStack(spacing: 0) { Design.text.frame(width: g.size.width * 0.7); Design.accent.frame(width: g.size.width * 0.08); Design.text.opacity(0.15) } }.frame(height: 16).clipShape(Capsule())
                    storageLine("Used by games", "1.51 TB", Design.text)
                    storageLine("Reserved by queue", "10.1 GB", Design.accent)
                    storageLine("Free", "412 GB", Design.muted)
                    Rectangle().fill(Design.text.opacity(0.1)).frame(height: 1)
                    Text("Downloads pause automatically while you play.").font(Design.body(22)).foregroundStyle(Design.secondary).lineSpacing(6)
                }.padding(28).background(Design.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                Text("Preview queue · no files are being downloaded").font(Design.body(18)).foregroundStyle(Design.muted)
            }.frame(width: 524)
        }.offset(x: 96, y: 150)
    }
    private func storageLine(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 12) { Circle().fill(color).frame(width: 10, height: 10); Text(title); Spacer(); Text(value).foregroundStyle(Design.secondary) }.font(Design.body(22))
    }
}

struct SettingsScreen: View {
    @Bindable var model: LibraryModel
    let sections = ["Account", "Library", "Display", "Controller", "About"]
    var settings: [(String, String, String)] {
        switch model.settingsSection {
        case 0: [("Steam", "Using designer preview data", "Not connected")]
        case 1: [("Refresh library", "Your games and artwork, up to date", "Refresh"), ("Games volume", "/Volumes/VM/GameNative/games", "Change ›"), ("Download while playing", "Downloads pause automatically when a game starts", "Off"), ("Runtime", "CrossOver integration is a later milestone", "Not connected")]
        case 2: [("Display", "A 1920 × 1080 canvas, scaled to your window", "Change ›"), ("Reduced motion", "Keep the focus ring; turn off scaling and transitions", model.reducedMotion ? "On" : "Off")]
        case 3: [("Controller", model.controllerName ?? "No controller connected · keyboard navigation available", "Button test")]
        default: [("Big Screen", "Native UI preview · Barlow / Barlow Condensed", "v0.1")]
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            VStack(spacing: 6) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    Text(section).font(Design.condensed(28, bold: model.settingsSection == index))
                        .foregroundStyle(model.settingsSection == index ? Design.text : Design.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).frame(height: 60)
                        .background(model.settingsSection == index ? Design.text.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .focusRing(model.settingsRailFocused && model.settingsSection == index, compact: true)
                        .onTapGesture { model.settingsSection = index; model.settingsIndex = 0 }
                }
            }.frame(width: 300)
            VStack(alignment: .leading, spacing: 24) {
                SectionLabel(text: sections[model.settingsSection])
                ForEach(Array(settings.enumerated()), id: \.offset) { index, setting in
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) { Text(setting.0).font(Design.condensed(30)); Text(setting.1).font(Design.body(22)).foregroundStyle(Design.secondary) }
                        Spacer()
                        if setting.2 == "On" || setting.2 == "Off" {
                            Capsule().fill(setting.2 == "On" ? Design.accent : Design.text.opacity(0.15)).frame(width: 84, height: 44)
                                .overlay(alignment: setting.2 == "On" ? .trailing : .leading) { Circle().fill(setting.2 == "On" ? Design.background : Design.secondary).frame(width: 36, height: 36).padding(4) }
                        } else { Text(setting.2).font(Design.condensed(26, bold: false)).padding(.horizontal, 22).frame(height: 56).overlay(RoundedRectangle(cornerRadius: 8).stroke(Design.text.opacity(0.2), lineWidth: 2)) }
                    }.padding(.horizontal, 30).padding(.vertical, 26).background(Design.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .focusRing(!model.settingsRailFocused && model.settingsIndex == index)
                        .onTapGesture { model.settingsRailFocused = false; model.settingsIndex = index; model.activateSetting() }
                }
            }.frame(width: 1380)
        }.offset(x: 96, y: 150)
    }
}

struct ModalLayer: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack(alignment: .trailing) {
            Design.background.opacity(0.72).onTapGesture { model.panel = nil }
            if model.panel == .search {
                SearchKeyboard(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .information(let message) = model.panel {
                VStack(alignment: .leading, spacing: 30) {
                    Text("Design preview").font(Design.condensed(48))
                    Text(message).font(Design.body(26)).foregroundStyle(Design.secondary).lineSpacing(8)
                    ActionButton(title: "Got it", primary: true, focused: true, reducedMotion: model.reducedMotion) { model.panel = nil }
                }.padding(44).frame(width: 720).background(Design.panel, in: RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.7), radius: 50, y: 40).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 30) {
                    Text(model.panel == .filters ? "Sort & filter" : model.panel == .compatibility ? "Compatibility" : model.focusedGame?.title ?? "Game")
                        .font(Design.condensed(48))
                    if model.panel == .compatibility { Text("Your rating · preview only").font(Design.body(22)).foregroundStyle(Design.secondary) }
                    ForEach(Array(model.panelActions.enumerated()), id: \.offset) { index, title in
                        Button { model.panelIndex = index; model.activatePanel() } label: {
                            HStack {
                                Text(title).font(Design.body(26, weight: "Medium"))
                                Spacer()
                                if model.panel == .filters && ((title == "Name" && !model.sortByPlaytime) || (title == "Playtime" && model.sortByPlaytime)) { Image(systemName: "checkmark").foregroundStyle(Design.accent) }
                            }.padding(18).background(model.panelIndex == index ? Design.text.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8)).focusRing(model.panelIndex == index, compact: true)
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    if model.panel == .filters { Text("\(model.filteredGames.count) games match").font(Design.body(24)).foregroundStyle(Design.secondary) }
                    LegendItem(glyph: model.playStationGlyphs ? "○" : "B", title: "Close")
                }.padding(.horizontal, 60).padding(.top, 150).padding(.bottom, 70).frame(width: 640, height: 1080).background(Design.panel).shadow(color: .black.opacity(0.5), radius: 40, x: -20)
            }
        }.frame(width: 1920, height: 1080)
    }
}
struct SearchKeyboard: View {
    @Bindable var model: LibraryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Text("Search your library").font(Design.condensed(40)); Spacer(); Text("\(model.filteredGames.count) results").font(Design.body(22)).foregroundStyle(Design.secondary) }
            HStack { Image(systemName: "magnifyingglass"); Text(model.query.isEmpty ? "Search games…" : model.query).foregroundStyle(model.query.isEmpty ? Design.muted : Design.text); Rectangle().fill(Design.accent).frame(width: 3, height: 34); Spacer() }
                .font(Design.body(30, weight: "Medium")).padding(.horizontal, 22).frame(height: 64).background(Design.text.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(spacing: 8) {
                ForEach(Array(model.searchKeys.enumerated()), id: \.offset) { row, keys in
                    HStack(spacing: 8) {
                        ForEach(Array(keys.enumerated()), id: \.offset) { column, key in
                            Text(key).font(Design.body(28, weight: "Medium")).frame(width: key == "Space" ? 520 : key == "Done" ? 180 : 96, height: 64)
                                .background(Design.text.opacity(key.count > 1 ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 8))
                                .focusRing(model.keyRow == row && model.keyColumn == column, compact: true)
                                .onTapGesture { model.keyRow = row; model.keyColumn = column; model.activateKey() }
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 30) { LegendItem(glyph: "□", title: "Backspace"); LegendItem(glyph: "△", title: "Space"); LegendItem(glyph: "○", title: "Done") }.padding(.top, 8)
        }.padding(28).frame(width: 1280).background(Design.panel, in: RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.7), radius: 50, y: 40)
    }
}
