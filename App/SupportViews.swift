import SwiftUI
import Domain

struct DownloadsScreen: View {
    @Bindable var model: LibraryModel
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            DownloadQueue(model: model).frame(width: 1188, height: 894).offset(x: -24, y: -24)
            DownloadsStorageCard(model: model).frame(width: 524)
        }.offset(x: 96, y: 150)
    }

}

struct SettingsScreen: View {
    @Bindable var model: LibraryModel
    let sections = ["Account", "Library", "Display", "Controller", "About", "Audio"]
    var settings: [(String, String, String)] {
        switch model.settingsSection {
        case 0: [("Steam", model.isPreview ? "Using designer preview data" : model.identity.map { "Signed in as \($0.displayName)" } ?? "Sign in to see your games", model.identity == nil ? "Sign in" : "Sign out")]
        case 1: [("Refresh library", model.syncError ?? (model.syncing ? "Loading your library…" : "Refresh your games and artwork"), model.syncing ? "Refreshing" : "Refresh"), ("Games volume", model.gamesVolume?.lastKnownRoot.path ?? (model.isPreview ? "/Volumes/VM/Big Screen/games" : "Not configured"), "Change ›"), ("Download while playing", "Downloads pause automatically when a game starts", model.downloadWhilePlaying ? "On" : "Off"), ("Runtime", model.runtimeInfo.map { "CrossOver \($0.version ?? "not found") · Template \($0.templateVersion)" } ?? "Checking game setup", model.runtimeInfo?.templateReady == true && model.runtimeInfo?.failure == nil ? "Ready ›" : "Review ›")]
        case 2: [
            ("Preferred display", model.displaySummary, "Change ›"),
            ("Fullscreen", model.fullscreenTransitioning ? "Switching window mode…" : "Fill the display · Control–Command–F", model.isFullscreen ? "On" : "Off"),
            ("Start in fullscreen", "Open Big Screen in fullscreen on your preferred display", model.startInFullscreen ? "On" : "Off"),
            ("Reduced motion", "Keep the focus ring; turn off scaling and transitions", model.reducedMotion ? "On" : "Off")
        ]
        case 5: [("Preferred audio device", model.audioSummary, "Change ›")]
        case 3: [("Connected controllers", model.connectedControllers.isEmpty ? "No controller connected · keyboard navigation available" : model.connectedControllers.map(\.name).joined(separator: " · "), "Button test")]
        default: [("Big Screen", model.runtimeInfo.map { "CrossOver \($0.version ?? "not detected") · Template \($0.templateVersion)" } ?? "Your living-room game library", "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")"),
            ("Logs folder", model.logArchiveError ?? "Install and play-session diagnostics · last 10 per game", "Open in Finder"),
            ("Reset app data", "Start setup again · installed games and saves are kept", "Review reset"),
            ("Quit Big Screen", "Close the launcher · downloads pause and can resume next time", "Quit")]
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
            .task {
                while !Task.isCancelled {
                    model.refreshAudioDevices()
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
    }
}

struct ModalLayer: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack(alignment: .trailing) {
            Design.background.opacity(0.72).onTapGesture {
                if model.panel == .resetAppData { model.closeResetAppData() }
                else if case .uninstall(let id) = model.panel { model.activateUninstall(.cancel, id: id) }
                else if case .cloudSaves(let id) = model.panel { model.activateCloud(.close, id: id) }
                else { model.panel = nil }
            }
            if model.panel == .resetAppData {
                ResetAppDataDialog(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.panel == .filters {
                LibraryFilterSheet(model: model)
            } else if model.panel == .controllerTest {
                ControllerTestView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isEditingText {
                SearchKeyboard(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .confirmation(let intent) = model.panel {
                ConfirmDialog(model: model, intent: intent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .installOffer(let gameID) = model.panel {
                InstallOfferDialog(model: model, gameID: gameID).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .launchOptions(let gameID) = model.panel {
                LaunchOptionsDialog(model: model, gameID: gameID).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .logs(let gameID) = model.panel {
                LogViewer(model: model, gameID: gameID).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .cloudSaves(let gameID) = model.panel {
                CloudSaveDialog(model: model, gameID: gameID).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .uninstall(let gameID) = model.panel {
                UninstallDialog(model: model, gameID: gameID).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .information(let message) = model.panel {
                VStack(alignment: .leading, spacing: 30) {
                    Text(model.isPreview ? "Design preview" : "Big Screen").font(Design.condensed(48))
                    Text(message).font(Design.body(26)).foregroundStyle(Design.secondary).lineSpacing(8)
                    ActionButton(title: "Got it", primary: true, focused: true, reducedMotion: model.reducedMotion) { model.panel = nil }
                }.padding(44).frame(width: 720).background(Design.panel, in: RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.7), radius: 50, y: 40).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 30) {
                    Text(model.panelTitle)
                        .font(Design.condensed(48))
                    if model.panel == .persistenceFailure { Text(model.persistenceError ?? "The library database is unavailable.").font(Design.body(24)).foregroundStyle(Design.secondary) }
                    if model.panel == .compatibility { Text(model.isPreview ? "Your rating · preview library" : "Your rating").font(Design.body(22)).foregroundStyle(Design.secondary) }
                    if model.panel == .signOut { Text("Installed games, saves, collections and play history stay on this Mac.").font(Design.body(24)).foregroundStyle(Design.secondary) }
                    PanelActionList(model: model)
                    if let note = model.downloadHistoryNote { Text(note).font(Design.body(22)).foregroundStyle(Design.secondary).lineSpacing(4) }
                    if model.panel == .compatibility, let id = model.focusedGame?.id {
                        Text(model.compatibilityNotes[id].flatMap { $0.isEmpty ? nil : $0 } ?? "Add a note about settings, controls or anything that needs a workaround.")
                            .font(Design.body(22)).foregroundStyle(Design.secondary).lineLimit(3)
                    }
                    Spacer()
                    if model.panel == .filters { Text("\(model.filteredGames.count) games match").font(Design.body(24)).foregroundStyle(Design.secondary) }
                    LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "ESC" : model.playStationGlyphs ? "○" : "B", title: "Close")
                }.padding(.horizontal, 60).padding(.top, 150).padding(.bottom, 70).frame(width: 640, height: 1080).background(Design.panel).shadow(color: .black.opacity(0.5), radius: 40, x: -20)
            }
        }.frame(width: 1920, height: 1080)
    }
}
struct SearchKeyboard: View {
    @Bindable var model: LibraryModel
    private var keyboard: Bool { model.controllerName == nil || model.keyboardNavigation }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Text(model.keyboardTitle).font(Design.condensed(40)); Spacer(); if model.panel == .search { Text("\(model.filteredGames.count) results").font(Design.body(22)).foregroundStyle(Design.secondary) } }
            HStack(spacing: 0) {
                Image(systemName: model.panel == .search ? "magnifyingglass" : "pencil").padding(.trailing, 16).foregroundStyle(Design.secondary)
                Text(model.maskedText ? String(repeating: "•", count: model.textEditor.beforeCursor.count) : model.textEditor.beforeCursor)
                    .truncationMode(.head)
                Rectangle().fill(Design.accent).frame(width: 3, height: 34).padding(.horizontal, 2)
                Text(model.maskedText ? String(repeating: "•", count: model.textEditor.afterCursor.count) : model.textEditor.afterCursor)
                Spacer(minLength: 0)
            }.font(Design.body(30, weight: "Medium")).lineLimit(1)
                .padding(.horizontal, 22).frame(height: 64).background(Design.text.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            if let error = model.keyboardError { Text(error).font(Design.body(22)).foregroundStyle(Design.red) }
            VStack(spacing: 8) {
                ForEach(Array(model.searchKeys.enumerated()), id: \.offset) { row, keys in
                    HStack(spacing: 8) {
                        ForEach(Array(keys.enumerated()), id: \.offset) { column, key in
                            Text(key).font(Design.body(28, weight: "Medium")).frame(width: model.keyboardKeyWidth(key), height: 64)
                                .background(Design.text.opacity(key.count > 1 ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 8))
                                .focusRing(model.keyRow == row && model.keyColumn == column, compact: true)
                                .onTapGesture { model.keyPreferredX = nil; model.keyRow = row; model.keyColumn = column; model.activateKey() }
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 26) {
                if keyboard {
                    LegendItem(glyph: "⌫", title: "Backspace")
                    HStack(spacing: 10) {
                        Glyph(text: "SHIFT TAB"); Glyph(text: "TAB")
                        Text("Cursor").font(Design.body(22, weight: "Medium"))
                    }
                    LegendItem(glyph: "CMD ENTER", title: "Done")
                    LegendItem(glyph: "ESC", title: model.panel == .search ? "Done" : "Cancel")
                } else {
                    LegendItem(glyph: model.playStationGlyphs ? "□" : "X", title: "Backspace")
                    LegendItem(glyph: model.playStationGlyphs ? "△" : "Y", title: "Space")
                    HStack(spacing: 10) {
                        Glyph(text: model.playStationGlyphs ? "L1" : "LB"); Glyph(text: model.playStationGlyphs ? "R1" : "RB")
                        Text("Cursor").font(Design.body(22, weight: "Medium"))
                    }
                    LegendItem(glyph: model.playStationGlyphs ? "OPTIONS" : "MENU", title: "Symbols")
                    LegendItem(glyph: model.playStationGlyphs ? "○" : "B", title: model.panel == .search ? "Done" : "Cancel")
                }
            }.padding(.top, 8)
        }.padding(28).frame(width: 1280).background(Design.panel, in: RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.7), radius: 50, y: 40)
    }
}

struct DownloadQueue: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.downloadRows) { row in
                if let heading = row.heading { SectionLabel(text: heading).offset(x: 24, y: row.headingTop - model.downloadScrollOffset) }
                DownloadCard(model: model, row: row).frame(width: 1140, height: row.height)
                    .offset(x: 24, y: row.top - model.downloadScrollOffset)
            }
            if model.downloadRows.isEmpty {
                VStack(spacing: 24) {
                    Text(model.hasDismissedFailedDownloads ? "No visible jobs" : "All caught up").font(Design.condensed(56))
                    Text(model.hasDismissedFailedDownloads ? "Open a game page to review dismissed installations." : "Games you install will appear here.").font(Design.body(26)).foregroundStyle(Design.secondary)
                    ActionButton(title: "Browse library", primary: true, focused: true) { model.browseAvailableGames() }
                }.frame(width: 1188, height: 700)
            }
        }.frame(width: 1188, height: 894, alignment: .topLeading).clipped()
            .animation(model.reducedMotion ? nil : .easeOut(duration: 0.18), value: model.downloadScrollOffset)
    }
}
struct DownloadCard: View {
    @Bindable var model: LibraryModel
    let row: DownloadRow
    var body: some View {
        let job = model.isPreview ? nil : model.liveJob(for: row.game.id)
        let active = job.map { $0.id == model.activeInstallID } ?? (row.game.status == .downloading)
        HStack(alignment: active ? .top : .center, spacing: 24) {
            Artwork(url: row.game.coverURL, fallbackURL: row.game.coverFallbackURL).frame(width: active ? 120 : 60, height: active ? 180 : 90).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: active ? 16 : 8) {
                Text(row.game.title).font(Design.condensed(active ? 36 : 30)).lineLimit(1)
                if let job {
                    HStack(spacing: 12) {
                        Text(model.downloadStatusTitle(for: job)).foregroundStyle(job.state == .failed ? Design.amber : active ? Design.accent : Design.secondary)
                        if let percentage = model.downloadPercentage(for: job) { Text(percentage).monospacedDigit().foregroundStyle(Design.accent) }
                    }.font(Design.body(active ? 24 : 22, weight: "Medium"))
                    if !active, let failure = job.failure {
                        Text(job.stageTitle + " · " + failure.reason).font(Design.body(20)).foregroundStyle(Design.secondary).lineLimit(2)
                    }
                    if active {
                        ProgressTrack(value: model.downloadProgress(for: job))
                        HStack(spacing: 16) {
                            Text(model.downloadBytesLabel(for: job)).frame(width: 420, alignment: .leading)
                            Text(model.transferSpeedLabel(for: job) ?? "").frame(width: 170, alignment: .leading)
                            Text(model.transferTimeLabel(for: job) ?? "").frame(maxWidth: .infinity, alignment: .leading)
                        }.font(Design.body(22)).monospacedDigit().foregroundStyle(Design.secondary).lineLimit(1)
                        Text(job.kind == .uninstall ? "Steam Cloud saves and library history are kept." : model.fileVerification(for: job)?.file ?? job.currentFile ?? "Your game will be ready after verification and setup.").font(Design.body(18)).foregroundStyle(Design.muted).lineLimit(1).truncationMode(.middle)
                    }
                } else if active {
                    Text(model.downloadPaused ? "Paused · 43%" : "Download · 43%").font(Design.body(24, weight: "Medium")).foregroundStyle(Design.accent)
                    ProgressTrack(value: 0.43)
                    Text(model.downloadPaused ? "3.8 of 8.9 GB · ready to resume" : "3.8 of 8.9 GB · 38 MB/s · 2 min 14 s left").font(Design.body(22)).foregroundStyle(Design.secondary)
                    Text("Estimate › Reserve space › Download › Verify › Prepare › Ready").font(Design.body(18)).foregroundStyle(Design.muted)
                } else {
                    HStack(spacing: 8) {
                        if row.game.status == .installed { Circle().fill(Design.green).frame(width: 8, height: 8) }
                        Text(row.game.status == .queued ? "Queued · \(row.game.size)" : "Installed").font(Design.body(22)).foregroundStyle(Design.secondary)
                    }
                }
            }
            if !active {
                Spacer()
                if let job { Image(systemName: job.state == .completed ? "checkmark.circle" : job.state == .failed ? "exclamationmark.circle" : job.state == .paused ? "pause.circle" : "ellipsis").font(.system(size: 26)).foregroundStyle(Design.secondary) }
                else { Text(row.game.status == .queued ? String((model.queueOrder.firstIndex(of: row.game.id) ?? 0) + 1) : "Today").font(Design.body(22)).foregroundStyle(Design.muted) }
            }
        }.padding(.horizontal, 20).padding(.vertical, active ? 20 : 14)
            .background(Design.text.opacity(active ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 8))
            .focusRing(model.downloadIndex == row.index)
            .onTapGesture { model.downloadIndex = row.index; model.perform(.confirm) }
    }
}
