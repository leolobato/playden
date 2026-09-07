import SwiftUI
import Domain

struct PanelActionList: View {
    @Bindable var model: LibraryModel
    var body: some View {
        let offset = max(0, Double(model.panelIndex - 5) * 80)
        ZStack(alignment: .topLeading) {
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
                }.buttonStyle(.plain).offset(x: 12, y: 12 + Double(index) * 80 - offset)
            }
        }.frame(width: 544, height: min(560, Double(model.panelActions.count) * 80 + 24), alignment: .topLeading)
            .clipped().padding(.leading, -12)
            .animation(model.reducedMotion ? nil : .easeOut(duration: 0.18), value: offset)
    }
}
struct ConfirmDialog: View {
    @Bindable var model: LibraryModel
    let intent: Confirmation
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(model.confirmationTitle(intent)).font(Design.condensed(40)).fixedSize(horizontal: false, vertical: true)
            Text(model.confirmationMessage(intent)).font(Design.body(24)).foregroundStyle(Design.secondary).lineSpacing(6)
            if case .uninstall = intent {
                HStack {
                    Text("Keep saves").font(Design.body(24, weight: "Medium"))
                    Spacer()
                    Glyph(text: model.playStationGlyphs ? "□" : "X")
                    Image(systemName: model.keepSaves ? "checkmark.square.fill" : "square").font(.system(size: 32)).foregroundStyle(Design.accent)
                }.padding(18).background(Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)).onTapGesture { model.keepSaves.toggle() }
            }
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
struct LogViewer: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack { Text(model.gameName(gameID)).font(Design.condensed(40)); Text("· Logs").font(Design.condensed(40)).foregroundStyle(Design.secondary); Spacer(); Text("No sessions yet").font(Design.body(22)).foregroundStyle(Design.muted) }
            VStack(alignment: .leading, spacing: 20) {
                if !model.isPreview, let job = model.liveJob(for: gameID) {
                    Text(job.statusTitle).foregroundStyle(Design.text)
                    if let failure = job.failure {
                        Text(failure.stage + " · " + failure.timestamp.formatted()).foregroundStyle(Design.secondary)
                        Text(failure.reason).foregroundStyle(Design.text)
                        ScrollView { Text(failure.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    } else { Text(job.bytesLabel).foregroundStyle(Design.secondary) }
                } else {
                    Text("No installation or play-session logs yet.").foregroundStyle(Design.text)
                    Text(model.isPreview ? "This library is using preview data. Logs will appear here after Steam and the game runtime are connected." : "Installation failures and play-session logs will appear here.").foregroundStyle(Design.secondary)
                }
            }.font(.system(size: 22, design: .monospaced)).padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(hex: 0x0A0908), in: RoundedRectangle(cornerRadius: 8))
            ActionButton(title: "Close", primary: true, focused: true, reducedMotion: model.reducedMotion) { model.panel = nil }
        }.padding(40).frame(width: 1728, height: 864).background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct InstallOfferDialog: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Install \(model.gameName(gameID))?").font(Design.condensed(40)).fixedSize(horizontal: false, vertical: true)
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
                    Text(offer.volume.lastKnownRoot.path).font(Design.body(20)).foregroundStyle(Design.muted).lineLimit(2)
                }
                if !offer.canInstall {
                    Text("Free up \(bytes(offer.plan.estimate.requiredBytes - offer.availableBytes)) to install this game.")
                        .font(Design.body(24, weight: "Medium")).foregroundStyle(Design.amber)
                }
            }
            HStack(spacing: 20) {
                ForEach(Array(model.panelActions.enumerated()), id: \.offset) { index, title in
                    Button { model.panelIndex = index; model.activatePanel() } label: {
                        Text(title).font(Design.condensed(28)).frame(maxWidth: .infinity).frame(height: 68)
                            .background(index == 1 ? Design.accent.opacity(0.18) : Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(index == 1 ? Design.accent.opacity(0.5) : Design.text.opacity(0.2), lineWidth: 2))
                            .focusRing(model.panelIndex == index)
                    }.buttonStyle(.plain)
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
