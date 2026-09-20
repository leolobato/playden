import SwiftUI
import Focus

extension LibraryModel {
    func moveInstallVolumeFocus(_ direction: Direction) {
        let end = installVolumeRows.count * 2
        switch direction {
        case .up: panelIndex = max(0, panelIndex - (panelIndex == end ? 1 : 2))
        case .down: panelIndex = min(end, panelIndex + 2)
        case .left: panelIndex = panelIndex == end ? end : panelIndex / 2 * 2
        case .right: panelIndex = min(end, panelIndex / 2 * 2 + 1)
        }
    }

    func activateInstallVolumePicker() {
        guard !volumeSaving else { return }
        guard let volume = installVolumeRows[safe: panelIndex / 2] else { panel = nil; return }
        if panelIndex.isMultiple(of: 2) {
            toggleInstallVolume(at: panelIndex / 2)
            panelIndex = min(panelIndex, installVolumeRows.count * 2)
        } else if let selection = enabledInstallVolumes.first(where: { $0.volumeID == volume.id }) {
            setDefaultInstallVolume(selection)
        }
    }
}

struct InstallVolumesPicker: View {
    @Bindable var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Games volumes").font(Design.condensed(48))
            Text("Check the volumes you want to use, then choose a default for new installs.")
                .font(Design.body(24)).foregroundStyle(Design.secondary)
            if let error = model.installVolumeError {
                Text(error).font(Design.body(22)).foregroundStyle(Design.amber)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(Array(model.installVolumeRows.enumerated()), id: \.element.id) { index, volume in
                            let enabled = model.enabledInstallVolumes.contains { $0.volumeID == volume.id }
                            let isDefault = model.gamesVolume?.volumeID == volume.id
                            VStack(alignment: .leading, spacing: 22) {
                                VolumeSetupRow(volume: volume, connected: model.availableVolumes.contains { $0.id == volume.id })
                                HStack(spacing: 24) {
                                    Button {
                                        model.panelIndex = index * 2; model.activateInstallVolumePicker()
                                    } label: {
                                        Label(enabled ? "Use for installs" : "Enable for installs", systemImage: enabled ? "checkmark.square.fill" : "square")
                                            .font(Design.body(24)).foregroundStyle(enabled ? Design.accent : Design.secondary)
                                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Design.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                    }.buttonStyle(.plain)
                                        .focusRing(model.panelIndex == index * 2, compact: true)
                                        .accessibilityValue(enabled ? "Checked" : "Unchecked")
                                    Button {
                                        model.panelIndex = index * 2 + 1; model.activateInstallVolumePicker()
                                    } label: {
                                        Label(isDefault ? "Default" : "Make default", systemImage: isDefault ? "star.fill" : "star")
                                            .font(Design.body(24)).foregroundStyle(isDefault ? Design.accent : Design.text)
                                            .padding(14).frame(width: 250)
                                            .background(Design.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                    }.buttonStyle(.plain).disabled(!enabled)
                                        .opacity(enabled ? 1 : 0.4)
                                        .focusRing(model.panelIndex == index * 2 + 1, compact: true)
                                }.disabled(model.volumeSaving)
                            }.padding(24).background(Design.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 10)).id(index)
                        }
                        if model.installVolumeRows.isEmpty {
                            Text(model.refreshingInstallVolumes ? "Looking for volumes…" : "No writable volumes found. Connect a drive to get started.")
                                .font(Design.body(24)).foregroundStyle(Design.secondary).padding(24)
                        }
                    }.padding(8)
                }.frame(maxHeight: 570)
                    .onChange(of: model.panelIndex) { _, index in proxy.scrollTo(min(index / 2, max(0, model.installVolumeRows.count - 1))) }
                    .onChange(of: model.installVolumeRows.map(\.id)) { _, _ in
                        model.panelIndex = min(model.panelIndex, model.installVolumeRows.count * 2)
                    }
            }
            HStack {
                Text(model.volumeSaving ? "Preparing volume…" : "Changes save automatically. Existing games stay where they are.")
                    .font(Design.body(20)).foregroundStyle(Design.secondary)
                Spacer()
                ActionButton(title: "Done", primary: true, focused: model.panelIndex == model.installVolumeRows.count * 2, reducedMotion: model.reducedMotion) { model.panel = nil }
            }
        }.padding(40).frame(width: 1200)
            .background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.7), radius: 50, y: 40)
            .task { await model.refreshInstallVolumes() }
    }
}
