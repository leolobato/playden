import Foundation
import Domain

extension LibraryModel {
    func detailSizeLabel(for game: Game) -> String {
        if [.installed, .driveDisconnected].contains(game.status) { return game.size }
        if let job = liveJob(for: game.id), job.kind == .install, ![.cancelled, .completed].contains(job.state), let plan = job.plan {
            return ByteCountFormatter.string(fromByteCount: plan.estimate.downloadBytes, countStyle: .file)
        }
        if game.id == detailID, let value = detailDownloadSize, let bytes = value.bytes {
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return value.precise ? size : "≈ " + size
        }
        return game.size == "—" && detailSizeLoading ? "Checking…" : game.size
    }
    func loadDetailDownloadSize() {
        detailSizeTask?.cancel(); detailSizeTask = nil
        detailDownloadSize = nil; detailSizeLoading = false
        guard !isPreview, let id = detailID, let source, let catalog,
              let game = games.first(where: { $0.id == id }), ![.installed, .driveDisconnected].contains(game.status) else { return }
        detailSizeLoading = true
        detailSizeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let accountKey = try await source.downloadSizeAccountKey()
                try Task.checkCancellation()
                guard self.detailID == id else { return }
                guard let key = accountKey else { self.detailSizeLoading = false; return }
                let cached = try catalog.downloadSize(for: id, accountKey: key)
                self.detailDownloadSize = cached
                if cached?.isFresh() == true { self.detailSizeLoading = false; return }
                // Rapid navigation can read cached values immediately without opening
                // a Steam connection for every briefly focused game.
                try await Task.sleep(for: .milliseconds(300))
                guard let record = try catalog.snapshot().entries.first(where: { $0.id == id })?.source else { self.detailSizeLoading = false; return }
                let response = try await source.downloadSize(for: record)
                try Task.checkCancellation()
                guard let estimate = response else { self.detailSizeLoading = false; return }
                guard self.detailID == id, estimate.accountKey == key,
                      try await source.downloadSizeAccountKey() == key else { return }
                try Task.checkCancellation()
                try catalog.saveDownloadSize(estimate, for: id)
                self.detailDownloadSize = try catalog.downloadSize(for: id, accountKey: key)
            } catch {
                // Keep stale cached data offline; size lookup must never interrupt browsing.
            }
            if !Task.isCancelled, self.detailID == id { self.detailSizeLoading = false }
        }
    }
    func cacheResolvedDownloadSize(_ plan: InstallPlan, accountKey: String?) {
        guard let accountKey, let catalog else { return }
        let value = DownloadSizeEstimate(accountKey: accountKey, bytes: plan.estimate.downloadBytes, manifestIDs: plan.manifestIDs, precise: true)
        do {
            try catalog.saveDownloadSize(value, for: plan.game.id)
            if detailID == plan.game.id { detailDownloadSize = value }
        } catch { /* Installation can continue if this optional cache cannot be saved. */ }
    }
}
