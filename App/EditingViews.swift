import SwiftUI
import Domain

struct PanelActionList: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    ForEach(Array(model.panelActions.enumerated()), id: \.offset) { index, title in
                        Button { model.panelIndex = index; model.activatePanel() } label: {
                            HStack {
                                if model.panel == .compatibility && index < 4 {
                                    Circle().fill([Design.muted, Design.green, Design.amber, Design.red][index]).frame(width: 12, height: 12)
                                }
                                Text(title).font(Design.body(26, weight: "Medium")).lineLimit(1)
                                Spacer(minLength: 8)
                                if model.panelItemSelected(at: index) { Image(systemName: "checkmark").foregroundStyle(Design.accent) }
                            }.padding(.horizontal, 18).frame(width: 520, height: 68)
                                .background(model.panelIndex == index ? Design.text.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .focusRing(model.panelIndex == index, compact: true)
                        }.buttonStyle(.plain).disabled(!model.panelActionEnabled(at: index)).id(index)
                    }
                }.padding(12)
            }.scrollIndicators(.visible)
                .onAppear { proxy.scrollTo(model.panelIndex) }
                .onChange(of: model.panelIndex) { _, index in
                    withAnimation(model.reducedMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(index) }
                }
        }.frame(width: 544, height: min(560, Double(model.panelActions.count) * 80 + 12), alignment: .topLeading)
            .padding(.leading, -12)
    }
}
struct ConfirmDialog: View {
    @Bindable var model: LibraryModel
    let intent: Confirmation
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(model.confirmationTitle(intent)).font(Design.condensed(40)).fixedSize(horizontal: false, vertical: true)
            Text(model.confirmationMessage(intent)).font(Design.body(24)).foregroundStyle(Design.secondary).lineSpacing(6)
            HStack(spacing: 20) {
                ForEach(Array(model.panelActions.enumerated()), id: \.offset) { index, title in
                    Button { model.panelIndex = index; model.activatePanel() } label: {
                        Text(title).font(Design.condensed(28)).frame(maxWidth: .infinity).frame(height: 68)
                            .background(index == 1 ? (isInstall ? Design.accent.opacity(0.18) : Design.red.opacity(0.18)) : Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(index == 1 ? (isInstall ? Design.accent : Design.red).opacity(0.5) : Design.text.opacity(0.2), lineWidth: 2))
                            .focusRing(model.panelIndex == index)
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 12)
        }.padding(40).frame(width: 720).background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.7), radius: 50, y: 40)
    }
    private var isInstall: Bool { if case .install = intent { true } else { false } }
}

/// Picks the build before the install offer, which then shows only that build.
struct PlatformPickerDialog: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Install \(model.gameName(gameID))?").font(Design.condensed(40)).fixedSize(horizontal: false, vertical: true)
                Text("This game has a Windows and a Mac version. Choose one to install.").font(Design.body(24)).foregroundStyle(Design.secondary)
            }
            VStack(spacing: 16) {
                ForEach(Array(model.installPlatformChoices.enumerated()), id: \.offset) { index, platform in
                    Button { model.panelIndex = index; model.activatePanel() } label: {
                        HStack(spacing: 24) {
                            Image(systemName: platform == .macOS ? "apple.logo" : "pc").font(.system(size: 34, weight: .medium)).frame(width: 48)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(platform.title).font(Design.condensed(32))
                                Text((platform == .macOS ? "Runs natively" : "Runs with CrossOver") + (model.storeHasCloudSaves(gameID) ? " · Steam Cloud saves" : ""))
                                    .font(Design.body(22)).foregroundStyle(Design.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 28).frame(maxWidth: .infinity, minHeight: 104)
                            .background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Design.text.opacity(0.2), lineWidth: 2))
                            .focusRing(model.panelIndex == index)
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                let cancel = model.installPlatformChoices.count
                ActionButton(title: "Cancel", focused: model.panelIndex == cancel, reducedMotion: model.reducedMotion) {
                    model.panelIndex = cancel; model.activatePanel()
                }
            }
        }.padding(40).frame(width: 800).background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.7), radius: 50, y: 40)
    }
}

struct InstallOfferDialog: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Install \(model.gameName(gameID))?").font(Design.condensed(40)).fixedSize(horizontal: false, vertical: true)
            if let platforms = model.games.first(where: { $0.id == gameID })?.platforms, platforms.count > 1 || model.installPlatform == .macOS {
                Text(model.installPlatform == .macOS ? "Mac version · runs natively" : "Windows version · runs with CrossOver")
                    .font(Design.body(24, weight: "Medium")).foregroundStyle(Design.text)
            }
            if let destination = model.installDestination {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(destination.volumeID == model.gamesVolume?.volumeID ? "Install on · default" : "Install on").font(Design.body(20)).foregroundStyle(Design.secondary)
                        Text(model.volumeLabel(destination)).font(Design.body(24, weight: "Medium")).lineLimit(1).truncationMode(.middle)
                        if model.volumeLabel(destination) != destination.lastKnownRoot.path {
                            Text(destination.lastKnownRoot.path).font(Design.body(20)).foregroundStyle(Design.muted).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    if let index = model.panelActions.firstIndex(of: "Choose volume…") {
                        ActionButton(title: "Choose volume…", focused: model.panelIndex == index, reducedMotion: model.reducedMotion) {
                            model.panelIndex = index; model.activatePanel()
                        }.fixedSize()
                    }
                }.padding(.horizontal, 24).padding(.vertical, 18).background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.resolvingInstall {
                HStack(spacing: 20) {
                    ProgressView().controlSize(.large)
                    Text(model.installOffer == nil ? "Checking game files and space…" : "Adding to downloads…").font(Design.body(24)).foregroundStyle(Design.secondary)
                }.frame(height: 100)
            } else if let error = model.installOfferError {
                Text(error).font(Design.body(24)).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let offer = model.installOffer {
                HStack(spacing: 16) {
                    sizeCard("Download", offer.plan.estimate.downloadBytes)
                    sizeCard("Installed size", offer.plan.estimate.installedBytes)
                }
                VStack(alignment: .leading, spacing: 16) {
                    sizeLine("Space needed to install", offer.plan.estimate.requiredBytes)
                    sizeLine("Available after queued games", offer.availableBytes)
                }
                if !offer.canInstall {
                    Text("Free up \(bytes(offer.plan.estimate.requiredBytes - offer.availableBytes)) to install this game.")
                        .font(Design.body(24, weight: "Medium")).foregroundStyle(Design.amber)
                }
            }
            HStack(spacing: 20) {
                ForEach(Array(model.panelActions.enumerated()), id: \.offset) { index, title in
                    if title != "Choose volume…" {
                        Button { model.panelIndex = index; model.activatePanel() } label: {
                            Text(title).font(Design.condensed(28)).frame(maxWidth: .infinity).frame(height: 68)
                                .background(index == 1 ? Design.accent.opacity(0.18) : Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(index == 1 ? Design.accent.opacity(0.5) : Design.text.opacity(0.2), lineWidth: 2))
                                .focusRing(model.panelIndex == index)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(.top, 12)
        }.padding(40).frame(width: 800).background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.7), radius: 50, y: 40)
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    private func sizeCard(_ label: String, _ count: Int64) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(Design.body(22)).foregroundStyle(Design.secondary)
            Text(bytes(count)).font(Design.condensed(36))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24).background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
    private func sizeLine(_ label: String, _ count: Int64) -> some View {
        HStack { Text(label).foregroundStyle(Design.secondary); Spacer(); Text(bytes(count)) }.font(Design.body(22))
    }
}
