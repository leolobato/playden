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
            ZStack(alignment: .topLeading) {
                Group {
                    switch model.tab {
                    case .home: HomeScreen(model: model)
                    case .library: LibraryScreen(model: model)
                    case .downloads: DownloadsScreen(model: model)
                    case .settings: SettingsScreen(model: model)
                    }
                }
                .environment(\.showsFocusRing, !model.tabsFocused && !model.sessionIssueFocused && model.panel == nil)
                .simultaneousGesture(TapGesture().onEnded { model.tabsFocused = false })
                TopBar(model: model).frame(width: 1728, height: 56).offset(x: 96, y: 54)
            }.frame(width: 1920, height: 1080, alignment: .topLeading)
                .environment(\.showsFocusRing, !model.sessionIssueFocused && model.panel == nil)
                .opacity(model.detailID == nil ? 1 : 0)
                .allowsHitTesting(model.detailID == nil)
                .accessibilityHidden(model.detailID != nil)
            if model.detailID != nil, let game = model.focusedGame {
                GamePage(model: model, game: game)
                    .environment(\.showsFocusRing, !model.sessionIssueFocused && model.panel == nil)
                    .transition(model.reducedMotion ? .identity : .opacity.combined(with: .offset(y: 24)))
                    .zIndex(1)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Design.background, location: 0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 150).offset(y: 930).allowsHitTesting(false).zIndex(2)
            BottomBar(model: model).frame(width: 1728, height: 40).offset(x: 96, y: 986).zIndex(3)
            if model.persistenceError != nil && model.panel == nil {
                Button { model.retryPersistence() } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(Design.amber)
                        Text("Changes aren’t saved").font(Design.body(24, weight: "Medium"))
                        LegendItem(glyph: model.controllerName == nil ? "O" : model.playStationGlyphs ? "OPTIONS" : "MENU", title: "Retry")
                    }.padding(22).background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).offset(x: 1150, y: 880).zIndex(3)
            }
            if let error = model.syncError, model.panel == nil, model.authScreen == nil {
                Text(error).font(Design.body(22)).foregroundStyle(Design.amber).lineLimit(2)
                    .padding(20).frame(width: 720, alignment: .leading).background(Design.panel, in: RoundedRectangle(cornerRadius: 10))
                    .offset(x: 1104, y: 880).zIndex(3)
            }
            if model.setupScreen != nil && model.setupScreen != .account { SetupView(model: model).environment(\.showsFocusRing, model.panel == nil).transition(.opacity).zIndex(4) }
            if model.authScreen != nil { AuthenticationView(model: model).environment(\.showsFocusRing, model.panel == nil).transition(.opacity).zIndex(4) }
            if model.panel != nil { ModalLayer(model: model).transition(.opacity).zIndex(5) }
            NotificationToasts(model: model).offset(x: 1264, y: 730).zIndex(6)
            if let issue = model.sessionIssue, model.showsSessionIssue {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.stage).font(Design.condensed(28))
                        Text(issue.reason).font(Design.body(22)).foregroundStyle(Design.secondary).lineLimit(2)
                    }
                    HStack(spacing: 16) {
                        ForEach(Array(model.sessionIssueActions.enumerated()), id: \.offset) { index, title in
                            ActionButton(title: title, focused: model.sessionIssueFocused && model.sessionIssueIndex == index, reducedMotion: model.reducedMotion) {
                                model.sessionIssueIndex = index; model.activateSessionIssue()
                            }
                        }
                        Spacer()
                        LegendItem(glyph: model.keyboardNavigation || model.controllerName == nil ? "T" : model.playStationGlyphs ? "△" : "Y", title: "Notification actions")
                    }
                }.padding(24).frame(width: 1100).background(Design.panel, in: RoundedRectangle(cornerRadius: 12)).offset(x: 96, y: 750).zIndex(6)
            }
            if model.isLaunchingGame && model.panel == nil { LaunchingGameView(model: model).transition(.opacity).zIndex(7) }
            if model.exitOverlay && model.fixedClock { GameExitOverlay(model: model).zIndex(8) }
        }.frame(width: 1920, height: 1080).clipped().foregroundStyle(Design.text)
            .environment(\.colorScheme, .dark)
            .animation(model.reducedMotion ? nil : .easeInOut(duration: 0.28), value: model.detailID)
            .animation(model.reducedMotion ? nil : .easeOut(duration: 0.2), value: model.panel != nil)
            .animation(model.reducedMotion ? nil : .easeInOut(duration: 0.28), value: model.isLaunchingGame)
            .task(id: model.focusedGame?.id) {
                guard let game = model.focusedGame, model.tab != .settings else { return }
                // Warm detail art after focus settles, so opening a tile can immediately animate it.
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                for url in [game.heroURL, game.logoURL].compactMap({ $0 }) {
                    guard !Task.isCancelled else { return }
                    _ = await ArtworkCache.shared.image(for: url)
                }
            }
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
                            if tab == .downloads && model.pendingDownloadCount > 0 { Text("\(model.pendingDownloadCount)").font(Design.body(16, weight: "SemiBold")).foregroundStyle(Design.background).padding(.horizontal, 8).padding(.vertical, 5).background(Design.accent, in: Capsule()) }
                        }.padding(.horizontal, 22).frame(height: 52)
                            .foregroundStyle(model.tab == tab ? Design.text : Design.secondary)
                            .background(model.tab == tab ? Design.text.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.tab == tab ? Design.text.opacity(0.35) : .clear, lineWidth: 2))
                            .focusRing(model.tabsFocused && model.tab == tab, compact: true)
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            if model.canShowGameControls {
                Button { model.showGameControls() } label: {
                    Label("Quit game", systemImage: "stop.circle")
                        .font(Design.body(24, weight: "Medium")).foregroundStyle(Design.text)
                        .padding(.horizontal, 18).frame(height: 52)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Design.text.opacity(0.3), lineWidth: 2))
                }.buttonStyle(.plain).padding(.trailing, 24)
            }
            HStack(spacing: 22) {
                HStack(spacing: 12) {
                    Circle().fill(LinearGradient(colors: [Design.accent, Color(hex: 0x8A3D15)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 40, height: 40)
                    Text(model.isPreview ? "Preview" : model.identity?.displayName ?? "Offline").font(Design.body(24, weight: "Medium")).lineLimit(1).frame(maxWidth: 260).fixedSize(horizontal: true, vertical: false)
                }
                ClockLabel(fixed: model.fixedClock)
                Button { model.quitLauncherFromUI() } label: {
                    Image(systemName: "power").font(.system(size: 26)).foregroundStyle(Design.secondary)
                        .frame(width: 52, height: 52)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Design.text.opacity(0.2), lineWidth: 2))
                }.buttonStyle(.plain).help("Quit Playden").accessibilityLabel("Quit Playden")
                    .disabled(model.launcherQuitting)
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
    private var keyboard: Bool { model.controllerName == nil || model.keyboardNavigation }
    var body: some View {
        HStack(spacing: 30) {
            if model.showsSessionIssue && model.sessionIssueFocused {
                LegendItem(glyph: keyboard ? "↵" : model.playStationGlyphs ? "✕" : "A", title: "Select")
                LegendItem(glyph: keyboard ? "ESC" : model.playStationGlyphs ? "○" : "B", title: "Back")
                LegendItem(glyph: "← →", title: "Choose action")
            } else if model.tabsFocused && model.detailID == nil {
                LegendItem(glyph: "← →", title: "Switch tabs")
                LegendItem(glyph: keyboard ? "↵" : model.playStationGlyphs ? "✕" : "A", title: "Browse")
                LegendItem(glyph: keyboard ? "ESC" : model.playStationGlyphs ? "○" : "B", title: "Back")
            } else {
            LegendItem(glyph: keyboard ? "↵" : model.playStationGlyphs ? "✕" : "A", title: model.detailID != nil || model.tab == .settings ? "Select" : model.tab == .downloads && !model.isPreview && model.focusedGame != nil ? "Manage" : model.tab == .downloads && model.focusedGame?.status == .downloading ? (model.downloadPaused ? "Resume" : "Pause") : "Open")
            if model.detailID != nil || model.tab == .library { LegendItem(glyph: keyboard ? "ESC" : model.playStationGlyphs ? "○" : "B", title: "Back") }
            if (model.tab != .settings && model.focusedGame != nil) || model.showsSessionIssue { LegendItem(glyph: keyboard ? "T" : model.playStationGlyphs ? "△" : "Y", title: model.showsSessionIssue ? "Notification" : "More") }
            if model.detailID == nil && model.tab == .home && model.focusedGame != nil { LegendItem(glyph: keyboard ? "F" : model.playStationGlyphs ? "□" : "X", title: "Favorite") }
            if model.detailID == nil {
                if keyboard { LegendItem(glyph: "TAB", title: "Tabs") }
                if model.tab == .library { LegendItem(glyph: keyboard ? "O" : model.playStationGlyphs ? "OPTIONS" : "MENU", title: "Sort & filter") }
                else if !keyboard { HStack(spacing: 10) { Glyph(text: model.playStationGlyphs ? "L1" : "LB"); Glyph(text: model.playStationGlyphs ? "R1" : "RB"); Text("Tabs").font(Design.body(22, weight: "Medium")) } }
                if model.tab == .home || model.tab == .library { LegendItem(glyph: keyboard ? "/" : model.playStationGlyphs ? "PAD" : "VIEW", title: "Search") }
            }
            }
            if model.canShowGameControls {
                LegendItem(glyph: keyboard ? "⇧ HOME" : model.playStationGlyphs ? "PS" : "HOME",
                           title: keyboard ? "Game controls" : "Hold: game controls")
                    .onTapGesture { model.showGameControls() }
            }
            Spacer(minLength: 0)
            if model.detailID != nil, let game = model.focusedGame, game.status == .installed,
               model.liveJob(for: game.id).map({ $0.kind != .uninstall || $0.state == .completed }) ?? true { CloudStatusLabel(model: model, gameID: game.id) }
            if model.detailID == nil && model.tab != .downloads && model.tab != .settings, let download = model.activeDownload {
                if !model.isPreview, let job = model.liveJob(for: download.id) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 12) {
                            Image(systemName: job.kind == .uninstall ? "trash" : "arrow.down.to.line").foregroundStyle(Design.accent)
                            Text(download.title).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(model.downloadStatusTitle(for: job) + (model.downloadPercentage(for: job).map { " · " + $0 } ?? ""))
                                .foregroundStyle(Design.secondary)
                        }.font(Design.body(18, weight: "SemiBold"))
                        ProgressTrack(value: model.downloadProgress(for: job), height: 4)
                        Text(model.downloadStats(for: job)).font(Design.body(16)).foregroundStyle(Design.secondary).lineLimit(1)
                    }.frame(width: 490).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Design.panel, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    HStack(spacing: 16) {
                        Image(systemName: model.downloadPaused ? "pause.fill" : "arrow.down.to.line").foregroundStyle(Design.accent)
                        Text(download.title).font(Design.body(20, weight: "SemiBold"))
                        ProgressTrack(value: 0.43, height: 6).frame(width: 120)
                        Text(model.downloadPaused ? "Paused" : "43% · 38 MB/s").font(Design.body(20, weight: "SemiBold")).foregroundStyle(Design.secondary)
                    }.padding(.horizontal, 16).frame(height: 40).background(Design.text.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

struct HomeScreen: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            AmbientBackdrop(url: model.focusedGame?.heroURL, reducedMotion: model.reducedMotion)
                .frame(width: 1920, height: 1080)
            LinearGradient(colors: [.clear, Design.background.opacity(0.6), Design.background], startPoint: .top, endPoint: .bottom)
            if model.rows.isEmpty {
                VStack(spacing: 28) {
                    Text(!model.isPreview && model.identity == nil ? "Welcome to Playden" : "Your next adventure starts here").font(Design.condensed(56))
                    Text(!model.isPreview && model.identity == nil ? "Sign in to Steam to see your library." : model.syncing ? "Loading your library…" : "Find a game in your library and make yourself at home.").font(Design.body(26)).foregroundStyle(Design.secondary)
                    ActionButton(title: !model.isPreview && model.identity == nil ? "Sign in to Steam" : "Browse library", primary: true, focused: true, reducedMotion: model.reducedMotion) {
                        if !model.isPreview && model.identity == nil { model.beginSignIn() } else { model.browseAvailableGames() }
                    }
                }.frame(width: 1920, height: 1080)
            }
            FocusedHomeRows(model: model).frame(width: 1848, height: 894).offset(x: 72, y: 126)
        }
    }
}

struct LibraryScreen: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            LibraryRail(model: model).frame(width: 348, height: 840).offset(x: 72, y: 126)
            if model.libraryHasSummary {
                HStack {
                    Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(Design.secondary)
                    Text(model.query.isEmpty ? "Filtered library" : model.query).font(Design.body(30, weight: "Medium")).lineLimit(1)
                    Spacer()
                    Text("\(model.filteredGames.count) results").font(Design.body(24)).foregroundStyle(Design.secondary)
                }.padding(.horizontal, 22).frame(width: 1380, height: 64).background(Design.text.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).offset(x: 444, y: 150)
            }
            FocusedLibraryGrid(model: model)
                .frame(width: 1428, height: model.libraryViewportHeight + 54)
                .offset(x: 420, y: model.libraryHasSummary ? 216 : 126)
            if model.filteredGames.isEmpty {
                VStack(spacing: 24) {
                    Text(!model.isPreview && model.identity == nil && model.games.isEmpty && model.query.isEmpty ? "Your Steam library starts here" : model.refinements.isActive ? "No games match these filters" : model.query.isEmpty ? "Nothing here yet" : "No games match ‘\(model.query)’").font(Design.condensed(56))
                    Text(!model.isPreview && model.identity == nil && model.games.isEmpty && model.query.isEmpty ? "Sign in to bring your games to Playden." : model.refinements.isActive ? "Reset your filters, or browse all your games." : "Try another collection or clear your search.").font(Design.body(26)).foregroundStyle(Design.secondary)
                    ActionButton(title: !model.isPreview && model.identity == nil && model.games.isEmpty && model.query.isEmpty ? "Sign in to Steam" : "Browse all games", primary: true, focused: !model.railFocused) {
                        if !model.isPreview && model.identity == nil && model.games.isEmpty && model.query.isEmpty { model.beginSignIn() } else { model.browseAvailableGames() }
                    }
                }.frame(width: 1380, height: 650).offset(x: 444, y: 150)
            }
        }
    }
}


struct GamePage: View {
    @Bindable var model: LibraryModel
    let game: Game
    private var hasInstallProgress: Bool { !model.isPreview && model.liveJob(for: game.id).map { ![.completed, .cancelled].contains($0.state) } == true }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Artwork(url: game.heroURL, placeholderID: game.id, fadeIn: !model.reducedMotion).frame(width: 1920, height: 620)
            LinearGradient(stops: [.init(color: Design.background.opacity(0.4), location: 0), .init(color: .clear, location: 0.3), .init(color: .clear, location: 0.75), .init(color: Design.background, location: 1)], startPoint: .top, endPoint: .bottom).frame(height: 620)
            HStack { LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "ESC" : model.playStationGlyphs ? "○" : "B", title: model.tab.rawValue); Spacer(); ClockLabel(fixed: model.fixedClock) }.frame(width: 1728, height: 40).offset(x: 96, y: 54)
            Artwork(url: game.logoURL, title: game.title, fit: true, transparent: true, fadeIn: !model.reducedMotion).frame(width: 460, height: 160).shadow(color: .black.opacity(0.5), radius: 20, y: 8).offset(x: 96, y: 430)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(Array(model.detailActions.enumerated()), id: \.offset) { index, title in
                            ActionButton(title: title,
                                         primary: index == 0 && model.detailActionEnabled(at: index), detail: title == "Install" ? game.knownSize : nil, focused: model.detailAction == index, large: index == 0, reducedMotion: model.reducedMotion,
                                         systemImage: ["Favorite", "Favorited"].contains(title) ? (game.isFavorite ? "heart.fill" : "heart") : title == "Play" ? "play.fill" : title == "Quit game" ? "stop.fill" : nil,
                                         iconOnly: ["Favorite", "Favorited"].contains(title), highlighted: ["Favorite", "Favorited"].contains(title) && game.isFavorite) {
                                model.detailAction = index; model.activateDetail()
                            }.disabled(!model.detailActionEnabled(at: index))
                                .help(index == 1 ? (game.isFavorite ? "Remove from favorites" : "Add to favorites") : title).id(index)
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 18)
                }.scrollIndicators(.hidden).scrollClipDisabled()
                    .onChange(of: model.detailAction) { _, index in withAnimation(model.reducedMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(index) } }
            }.frame(width: 1776, height: 120).offset(x: 72, y: 622)
            HStack(alignment: .top, spacing: 80) {
                VStack(alignment: .leading, spacing: 24) {
                    if let message = model.installationDriveMessage {
                        Label(message, systemImage: "externaldrive.badge.exclamationmark")
                            .font(Design.body(22)).foregroundStyle(Design.amber).lineLimit(2)
                    }
                    if !model.isPreview, let job = model.liveJob(for: game.id), ![.completed, .cancelled].contains(job.state) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text(model.downloadStatusTitle(for: job)); Spacer(); if let percentage = model.downloadPercentage(for: job) { Text(percentage) } }.font(Design.body(22, weight: "Medium"))
                            Text(model.downloadStats(for: job)).font(Design.body(22)).foregroundStyle(Design.secondary)
                            ProgressTrack(value: model.downloadProgress(for: job), height: 8)
                            if let failure = job.failure { Text(failure.reason).font(Design.body(20)).foregroundStyle(Design.amber).lineLimit(2) }
                        }.padding(20).background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !hasInstallProgress && model.installationDriveMessage == nil {
                        Text(game.summary).font(Design.body(26)).foregroundStyle(Color(hex: 0xD6D0C8)).lineSpacing(7).lineLimit(model.compatibilityNotes[game.id]?.isEmpty == false ? 2 : 3)
                    }
                    if !hasInstallProgress { HStack(spacing: 12) {
                        if let outcome = game.lastSessionOutcome {
                            Label("Last session · \(outcome.displayTitle)", systemImage: outcome.symbol)
                                .font(Design.body(20, weight: "Medium"))
                                .foregroundStyle(outcome == .crash || outcome == .launchFailed ? Design.amber : Design.secondary)
                                .fixedSize().padding(.trailing, 8)
                        }
                        ForEach(Array(game.genres.prefix(game.lastSessionOutcome == nil ? 4 : 2)), id: \.self) { tag in
                            Text(tag).font(Design.body(20, weight: "Medium")).lineLimit(1)
                                .padding(.horizontal, 16).padding(.vertical, 8).background(Design.text.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }
                    } }
                    if !hasInstallProgress, let note = model.compatibilityNotes[game.id], !note.isEmpty {
                        Text(note).font(Design.body(20)).foregroundStyle(Design.secondary).lineLimit(2)
                    }
                }.frame(width: 1128, alignment: .leading)
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 40) { metadata("Playtime", game.hoursPlayed == 0 ? "Never played" : "\(game.hoursPlayed) hours"); metadata([.installed, .driveDisconnected].contains(game.status) ? "Size" : "Download", model.detailSizeLabel(for: game)) }
                    HStack(alignment: .top, spacing: 40) { metadata("Source", game.id.source.capitalized); metadata("Compatibility", game.compatibility.rawValue) }
                    HStack(alignment: .top, spacing: 40) {
                        metadata("Controller", model.isPreview ? "Full support" : game.controllerSupport == .full ? "Full support" : game.controllerSupport == .partial ? "Partial support" : game.controllerSupport == .none ? "No support" : "Unknown")
                        if let date = game.lastPlayedAt { metadata("Last played", date.formatted(.dateTime.month(.abbreviated).day())) }
                    }
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
