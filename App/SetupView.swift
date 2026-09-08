import SwiftUI
import Domain
import Runner

struct SetupView: View {
    @Bindable var model: LibraryModel
    var title: String {
        switch model.setupScreen {
        case .controller: "Connect your controller"
        case .permissions: "Permissions, explained."
        case .display: "Pick your screen."
        case .audio: "Choose your audio output."
        case .volume: "Where should games go?"
        default: model.runtimeInfo?.templateReady == true && !model.setupBusy && model.setupFailure == nil ? "Ready when you are." : "Preparing your Mac"
        }
    }
    var step: Int { switch model.setupScreen { case .controller, .display: 1; case .permissions: 2; case .account: 3; case .volume: 4; default: 5 } }
    var body: some View {
        if model.setupScreen == .runtime && !model.onboarding {
            RuntimeSettingsView(model: model)
        } else {
            setupBody.task {
                guard model.setupScreen == .audio else { return }
                while !Task.isCancelled {
                    model.refreshAudioDevices()
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }
    }
    private var setupBody: some View {
        ZStack(alignment: .topLeading) {
            Design.background
            LinearGradient(colors: [Design.accent.opacity(0.05), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            SectionLabel(text: model.onboarding ? "Set up · Step \(step) of 5" : model.setupScreen == .volume ? "Games volume" : model.setupScreen == .display ? "Display" : model.setupScreen == .audio ? "Audio" : "Game setup")
                .offset(x: 96, y: 60)
            VStack(alignment: .leading, spacing: 34) {
                Text(title).font(Design.condensed(72)).fixedSize(horizontal: false, vertical: true)
                if model.setupScreen == .controller { controllerInstructions }
                else if model.setupScreen == .permissions {
                    Text("macOS may ask for access when you choose a games drive or prepare a game. You can continue now and grant access when it is needed.")
                        .font(Design.body(30)).foregroundStyle(Design.secondary).lineSpacing(8)
                }
                else {
                    Text(model.setupScreen == .audio ? "Choose where your games play sound. Changes apply on the next launch. If the device is disconnected, games use the system default." : model.setupScreen == .volume ? "Pick a drive with room. You can change it later; games already installed stay where they are." : model.setupScreen == .display ? "Choose the display you’ll play on. Playden will remember it for next time." : "A one-time setup so Windows games can run." + (model.syncing ? " Your library is loading in the meantime." : " You can browse your library when this finishes."))
                        .font(Design.body(30)).foregroundStyle(Design.secondary).lineSpacing(8)
                }
                if let failure = model.setupFailure {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(failure.stage, systemImage: "exclamationmark.circle").font(Design.condensed(30)).foregroundStyle(Design.amber)
                        Text(failure.reason).font(Design.body(25)).foregroundStyle(Design.secondary).lineSpacing(5)
                    }
                }
                if model.setupScreen == .controller || model.setupScreen == .runtime || model.setupScreen == .permissions {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(model.setupActions.enumerated()), id: \.offset) { index, action in
                            ActionButton(title: action, primary: index == 0, focused: model.setupIndex == index, large: index == 0, reducedMotion: model.reducedMotion) { model.setupIndex = index; model.activateSetup() }
                        }
                    }.padding(.top, 16)
                }
            }.frame(width: model.setupScreen == .controller ? 860 : 760, alignment: .leading).offset(x: 96, y: 250)
            Group {
                if model.setupScreen == .controller { controllerArt }
                else if model.setupScreen == .runtime { runtimeProgress }
                else if model.setupScreen == .permissions { permissionInstructions }
                else { choices }
            }.frame(width: model.setupScreen == .controller ? 700 : 924, height: 690, alignment: .topLeading)
                .offset(x: model.setupScreen == .controller ? 1120 : 900, y: 250)
            HStack(spacing: 30) {
                LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "↵" : model.playStationGlyphs ? "✕" : "A", title: "Select")
                LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "ESC" : model.playStationGlyphs ? "○" : "B", title: "Back")
                if model.setupScreen == .controller && model.controllerName == nil {
                    Text("Keyboard arrows and Return work too").font(Design.body(22)).foregroundStyle(Design.secondary).padding(.leading, 40)
                }
            }.offset(x: 96, y: 986)
        }.frame(width: 1920, height: 1080).foregroundStyle(Design.text)
    }
    private var permissionInstructions: some View {
        VStack(alignment: .leading, spacing: 32) {
            permissionCard("Games drive", symbol: "externaldrive", text: "Allow access to your chosen drive when macOS asks, so Playden can install, update and remove games. Files & Folders in System Settings lets you review access later.")
            permissionCard("App Management · if requested", symbol: "app.badge", text: "This allows changes to other apps on your Mac. CrossOver can trigger this request under Playden’s name while running a game. If macOS requests it, review Playden in App Management. It is not controller permission.")
            Text("Permissions are managed by macOS. Opening Settings does not grant access, and Playden does not verify App Management status here.")
                .font(Design.body(23)).foregroundStyle(Design.secondary).lineSpacing(5)
        }.padding(32).frame(width: 924, alignment: .leading)
            .background(Design.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private func permissionCard(_ title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(Design.condensed(32))
            Text(text).font(Design.body(25)).foregroundStyle(Design.secondary).lineSpacing(5)
        }
    }
    private var controllerInstructions: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(["Hold Share and PS on the DualShock until the light bar flashes.", "Pair it in macOS Bluetooth settings. You may need a mouse for this step.", "Come back here. We will notice it."].enumerated()), id: \.offset) { index, text in
                HStack(alignment: .top, spacing: 20) {
                    Text("\(index + 1)").font(Design.body(24, weight: "SemiBold")).frame(width: 44, height: 44).background(Design.text.opacity(0.12), in: Circle())
                    Text(text).font(Design.body(28)).foregroundStyle(Design.secondary).lineSpacing(6)
                }
            }
        }
    }
    private var controllerArt: some View {
        VStack(spacing: 46) {
            PairingControllerArt().frame(width: 700, height: 410)
            HStack(spacing: 18) {
                if model.controllerName == nil { ProgressView().tint(Design.accent) }
                else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Design.green).font(.system(size: 30)) }
                Text(model.controllerName ?? "Waiting for a controller…").font(Design.body(26, weight: "Medium"))
            }.padding(30).frame(width: 700).background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private var runtimeProgress: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Setting up game runtime").font(Design.condensed(32))
                Spacer()
                Text(model.runtimeInfo?.templateReady == true && !model.setupBusy && model.setupFailure == nil ? "Ready" : model.templateStage == .checking ? "1 of 4" : model.templateStage == .creating ? "2 of 4" : model.templateStage == .configuring ? "3 of 4" : "4 of 4")
                    .font(Design.body(24, weight: "Medium")).foregroundStyle(Design.accent)
            }
            GeometryReader { geometry in
                Capsule().fill(Design.text.opacity(0.18))
                    .overlay(alignment: .leading) { Capsule().fill(Design.accent).frame(width: geometry.size.width * (model.templateStage == .ready ? 1 : model.templateStage == .checking ? 0.1 : model.templateStage == .creating ? 0.45 : model.templateStage == .configuring ? 0.65 : 0.85)) }
            }.frame(height: 10).padding(.bottom, 8)
            ForEach(Array([("Checking game runtime", TemplateStage.checking), ("Creating your game setup", .creating), ("Applying game settings", .configuring), ("Making sure it’s ready", .validating)].enumerated()), id: \.offset) { index, item in
                let stages: [TemplateStage] = [.checking, .creating, .configuring, .validating, .ready]
                let current = stages.firstIndex(of: model.templateStage) ?? 0
                HStack(spacing: 22) {
                    if model.setupBusy && current == index { ProgressView().tint(Design.accent).frame(width: 30) }
                    else { Image(systemName: current > index ? "checkmark.circle.fill" : "circle").font(.system(size: 28)).foregroundStyle(current > index ? Design.green : Design.muted).frame(width: 30) }
                    Text(item.0).font(Design.body(26)).foregroundStyle(current >= index ? Design.text : Design.muted)
                }
            }
            if model.setupFailure != nil {
                Text("Your library is still available. You can retry setup here or in Settings.").font(Design.body(24)).foregroundStyle(Design.secondary).lineSpacing(6).padding(.top, 10)
            }
        }.padding(32).frame(width: 924, alignment: .leading).background(Design.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private var choices: some View {
        VStack(alignment: .leading, spacing: 24) {
            if model.setupBusy {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 20) { ProgressView().tint(Design.accent); Text(model.volumeSaving ? "Checking access to this drive…" : "Looking for your games drives…").font(Design.body(28)) }
                    if model.volumeSaving { Text("If macOS asks, allow Playden to access the drive.").font(Design.body(24)).foregroundStyle(Design.secondary) }
                }.padding(32)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 18) {
                        ForEach(Array(model.setupActions.enumerated()), id: \.offset) { index, action in
                            let volume = model.setupScreen == .volume && !model.setupBusy && model.setupFailure == nil ? model.availableVolumes[safe: index] : nil
                            let display = model.setupScreen == .display ? model.displays[safe: index] : nil
                            Button { model.setupIndex = index; model.activateSetup() } label: {
                                Group {
                                if let volume { VolumeSetupRow(volume: volume) }
                                else { HStack(spacing: 22) {
                                    if display != nil { Image(systemName: "display").font(.system(size: 36)).foregroundStyle(Design.secondary) }
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(action).font(Design.condensed(34))
                                        if let display { Text(display.resolution).font(Design.body(23)).foregroundStyle(Design.secondary) }
                                    }
                                    Spacer()
                                    if model.setupScreen == .audio && (index == 0 ? model.selectedAudioDeviceUID == nil : model.audioDevices[safe: index - 1]?.id == model.selectedAudioDeviceUID && index <= model.audioDevices.count) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Design.accent).font(.system(size: 32))
                                    }
                                    if let display, display.id == model.preferredDisplay?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Design.accent).font(.system(size: 32)) }
                                } }
                                }.padding(28).frame(maxWidth: .infinity, minHeight: volume != nil ? 144 : display != nil ? 120 : 84)
                                    .background(action == "Continue" ? Design.accent.opacity(0.18) : Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                    .focusRing(model.setupIndex == index, compact: true)
                            }.buttonStyle(.plain).id(index)
                        }
                    }.padding(12)
                }.scrollIndicators(.hidden)
                    .onChange(of: model.setupIndex) { _, value in
                        withAnimation(model.reducedMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(value) }
                    }
            }
        }
    }
}
private struct VolumeSetupRow: View {
    let volume: GamesVolume
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(volume.name).font(Design.condensed(36))
                Text(volume.gamesRoot.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(Design.body(22)).foregroundStyle(Design.secondary).lineLimit(1).truncationMode(.middle)
                if let total = volume.totalBytes, total > 0 {
                    GeometryReader { geometry in
                        Capsule().fill(Design.text.opacity(0.18)).overlay(alignment: .leading) {
                            Capsule().fill(Design.text.opacity(0.7)).frame(width: geometry.size.width * max(0, min(1, 1 - Double(volume.freeBytes) / Double(total))))
                        }
                    }.frame(height: 8).padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Text("\(ByteCountFormatter.string(fromByteCount: volume.freeBytes, countStyle: .file)) free").font(Design.condensed(32)).fixedSize()
                if let total = volume.totalBytes { Text("of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))").font(Design.body(22)).foregroundStyle(Design.secondary) }
                if volume.isRecommended { Text("Recommended").font(Design.body(18)).foregroundStyle(Design.secondary) }
            }
        }
    }
}
