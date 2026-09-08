import SwiftUI
import Domain
import Installs

extension LibraryModel {
    func refreshGamesStorage() async {
        guard let selection = gamesVolume, let gamesStorageReader else { return }
        do {
            let installations = try catalog?.snapshot().entries.compactMap(\.installation) ?? []
            let snapshot = try await gamesStorageReader.snapshot(on: selection, installations: installations, jobs: installJobs)
            guard !Task.isCancelled, gamesVolume == selection else { return }
            gamesStorage = snapshot; gamesStorageError = nil
        } catch {
            guard !Task.isCancelled, gamesVolume == selection else { return }
            gamesStorage = nil
            gamesStorageError = (error as? OperationFailure)?.reason ?? "Storage information is unavailable. Check your games drive and try again."
        }
    }
    var downloadStorage: GamesStorageSnapshot? {
        if isPreview {
            return .init(volumeID: "preview", name: "VM", root: URL(fileURLWithPath: "/Volumes/VM/GameNative/games"),
                totalBytes: 2_000_000_000_000, freeBytes: 1_350_000_000_000, gamesBytes: 640_000_000_000, reservedBytes: 13_900_000_000)
        }
        guard let value = gamesStorage, value.volumeID == gamesVolume?.volumeID else { return nil }
        return .init(volumeID: value.volumeID, name: value.name, root: value.root, totalBytes: value.totalBytes,
            freeBytes: value.freeBytes, gamesBytes: value.gamesBytes,
            reservedBytes: gamesStorageReader == nil ? value.reservedBytes : InstallReservations.bytes(installJobs, on: value.volumeID))
    }
}

struct DownloadsStorageCard: View {
    @Bindable var model: LibraryModel
    private let otherColor = Color(red: 0.39, green: 0.37, blue: 0.35)
    private let freeColor = Design.text.opacity(0.15)
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionLabel(text: "Games volume" + (model.downloadStorage.map { " · " + $0.name } ?? ""))
            if let storage = model.downloadStorage {
                storageBar(storage)
                VStack(spacing: 14) {
                    line("Used by games", storage.gamesBytes.map(size) ?? "Unavailable", Design.text)
                    line("Reserved by queue", size(storage.reservedBytes), Design.accent)
                    line(storage.gamesBytes == nil ? "Used on drive" : "Other files", size(storage.otherBytes), otherColor)
                    line("Free after queue", size(storage.availableBytes), freeColor)
                }
                Text(size(storage.freeBytes) + " available of " + size(storage.totalBytes))
                    .font(Design.body(20)).foregroundStyle(Design.secondary)
                if storage.shortageBytes > 0 {
                    Text(size(storage.shortageBytes) + " more space needed to finish queued installs.")
                        .font(Design.body(22)).foregroundStyle(Design.amber)
                }
                if storage.gamesBytes == nil {
                    Text("Some game folders could not be measured. Rechecking automatically.")
                        .font(Design.body(20)).foregroundStyle(Design.amber)
                }
            } else {
                Text(model.gamesVolume == nil ? "Choose a games drive" : model.gamesStorageError == nil ? "Checking storage…" : "Storage unavailable")
                    .font(Design.condensed(30))
                Text(model.gamesStorageError ?? (model.gamesVolume == nil ? "Choose a drive in Settings › Library." : "Reading available space and game folders."))
                    .font(Design.body(22)).foregroundStyle(Design.secondary)
            }
            Rectangle().fill(Design.text.opacity(0.1)).frame(height: 1)
            Text(model.downloadWhilePlaying ? "Downloads continue while you play." : "Downloads pause while a game is running. Change in Settings › Library.")
                .font(Design.body(22)).foregroundStyle(Design.secondary).lineSpacing(4)
            if let path = model.downloadStorage?.root.path ?? model.gamesVolume?.lastKnownRoot.path {
                Text(path).font(Design.body(18)).foregroundStyle(Design.muted).lineLimit(2).truncationMode(.middle)
            }
            if let error = model.installPersistenceError { Text(error).font(Design.body(22)).foregroundStyle(Design.amber) }
        }
        .padding(24).background(Design.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .task(id: model.gamesVolume) {
            guard model.gamesStorageReader != nil, model.gamesVolume != nil else { return }
            model.gamesStorage = nil; model.gamesStorageError = nil
            while !Task.isCancelled {
                await model.refreshGamesStorage()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    private func line(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 11, height: 11)
            Text(title); Spacer(minLength: 8); Text(value).foregroundStyle(Design.text)
        }.font(Design.body(22)).foregroundStyle(Design.secondary)
    }
    private func storageBar(_ storage: GamesStorageSnapshot) -> some View {
        GeometryReader { geometry in
            let total = Double(max(1, storage.totalBytes))
            HStack(spacing: 0) {
                Design.text.frame(width: geometry.size.width * Double(storage.gamesBytes ?? 0) / total)
                otherColor.frame(width: geometry.size.width * Double(storage.otherBytes) / total)
                Design.accent.frame(width: geometry.size.width * Double(min(storage.freeBytes, storage.reservedBytes)) / total)
                freeColor
            }
        }.frame(height: 16).clipShape(Capsule()).accessibilityHidden(true)
    }
}
