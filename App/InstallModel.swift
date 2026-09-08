import Foundation
import Domain
import Installs

extension LibraryModel {
    func startInstallServices() {
        guard let installQueue else { return }
        installObserver = Task { [weak self] in
            do {
                if self?.sessions == nil { try await installQueue.start() }
                for await snapshot in await installQueue.updates() {
                    guard let self, !Task.isCancelled else { return }
                    self.receiveInstallNotifications(snapshot.jobs)
                    let focusedDownload = self.downloadGames[safe: self.downloadIndex]?.id
                    let completedBefore = Set(self.installJobs.filter { [.completed, .cancelled].contains($0.state) }.map(\.id))
                    self.installJobs = snapshot.jobs; self.activeInstallID = snapshot.activeJobID; self.installTransfer = snapshot.transfer; self.installPreparation = snapshot.preparation
                    self.reconcileLauncherQuitRequest()
                    self.installPersistenceError = snapshot.persistenceFailure?.reason
                    if Set(snapshot.jobs.filter { [.completed, .cancelled].contains($0.state) }.map(\.id)) != completedBefore { self.reloadCatalog() }
                    self.applyInstallStatuses()
                    if let focusedDownload, let index = self.downloadGames.firstIndex(where: { $0.id == focusedDownload }) { self.downloadIndex = index }
                    self.reconcileFocus()
                }
            } catch { self?.installPersistenceError = error.localizedDescription }
        }
    }
    func beginVerification(_ id: GameID) {
        guard let installQueue else { show(.information("The install queue is unavailable.")); return }
        Task { [weak self] in
            do {
                _ = try await installQueue.repair(id)
                guard let self else { return }
                self.reloadCatalog(); self.panel = nil; self.selectTab(.downloads)
                self.downloadIndex = self.downloadGames.firstIndex(where: { $0.id == id }) ?? 0
            } catch { self?.show(.information((error as? OperationFailure)?.reason ?? error.localizedDescription)) }
        }
    }
    func beginInstall(_ id: GameID) {
        guard let installQueue, let catalog else { show(.information(installPersistenceError ?? "The install queue is unavailable.")); return }
        guard let volume = gamesVolume else { openVolumeSetup(); return }
        installOfferTask?.cancel(); installOffer = nil; installOfferError = nil; installOfferRequiresSignIn = false; resolvingInstall = true
        show(.installOffer(id))
        installOfferTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let game = try catalog.snapshot().entries.first(where: { $0.id == id })?.source else { throw SourceFailure.unavailable }
                let sizeAccount = try? await self.source?.downloadSizeAccountKey()
                let offer = try await installQueue.offer(for: game, volume: volume)
                guard !Task.isCancelled, self.panel == .installOffer(id) else { return }
                if let sizeAccount, (try? await self.source?.downloadSizeAccountKey()) == sizeAccount {
                    self.cacheResolvedDownloadSize(offer.plan, accountKey: sizeAccount)
                }
                guard !Task.isCancelled, self.panel == .installOffer(id) else { return }
                self.installOffer = offer; self.resolvingInstall = false; self.panelIndex = 0
                if let index = self.games.firstIndex(where: { $0.id == id }) {
                    self.games[index].size = ByteCountFormatter.string(fromByteCount: offer.plan.estimate.downloadBytes, countStyle: .file)
                }
            } catch {
                guard !Task.isCancelled, self.panel == .installOffer(id) else { return }
                self.recordInstallOfferFailure(error); self.resolvingInstall = false; self.panelIndex = 1
            }
        }
    }
    func confirmInstall() {
        guard let offer = installOffer, offer.canInstall, let installQueue, !resolvingInstall else { return }
        resolvingInstall = true
        installOfferTask = Task { [weak self] in
            do {
                _ = try await installQueue.enqueue(offer)
                guard let self, !Task.isCancelled else { return }
                self.panel = nil; self.selectTab(.downloads)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.resolvingInstall = false; self.recordInstallOfferFailure(error)
            }
        }
    }
    private func recordInstallOfferFailure(_ error: Error) {
        installOfferError = (error as? OperationFailure)?.reason ?? error.localizedDescription
        let failure = error as? SourceFailure
        installOfferRequiresSignIn = failure == .signedOut || failure == .expired || failure == .credentialsRejected
    }
    var latestInstallJobs: [JobRecord] {
        var latest: [GameID: JobRecord] = [:]
        for job in installJobs.sorted(by: { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }) { latest[job.gameID] = job }
        func rank(_ job: JobRecord) -> Int {
            if job.id == activeInstallID { return 0 }
            switch job.state { case .running, .stopping: return 0; case .queued, .paused: return 1; case .failed: return 2; default: return 3 }
        }
        return latest.values.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if rank($0) >= 2 && $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.queuePosition != $1.queuePosition { return $0.queuePosition < $1.queuePosition }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    var visibleInstallJobs: [JobRecord] {
        latestInstallJobs.filter { downloadDismissals[$0.id]?.hides($0) != true }
    }
    func liveJob(for id: GameID) -> JobRecord? { latestInstallJobs.first { $0.gameID == id } }
    func applyInstallStatuses() {
        guard !isPreview else { return }
        for job in latestInstallJobs {
            guard let index = games.firstIndex(where: { $0.id == job.gameID }) else { continue }
            if job.kind == .uninstall {
                games[index].status = job.state == .completed ? .notInstalled : .installed
                continue
            }
            if ![.completed, .cancelled].contains(job.state), let plan = job.plan {
                games[index].size = ByteCountFormatter.string(fromByteCount: plan.estimate.downloadBytes, countStyle: .file)
            }
            if [.running, .stopping].contains(job.state) { games[index].status = .downloading }
            else if [.queued, .paused, .failed].contains(job.state) { games[index].status = .queued }
            else if job.state == .cancelled, games[index].status != .installed { games[index].status = .notInstalled }
        }
        applyInstallationDriveStatuses()
    }
    func game(for job: JobRecord) -> Game {
        if let game = games.first(where: { $0.id == job.gameID }) { return game }
        let source = job.plan?.game ?? job.originalInstallation?.game
        return Game(id: job.gameID, title: source?.title ?? "Game", coverURL: source?.coverURL, heroURL: source?.heroURL, logoURL: source?.logoURL)
    }
    func performLiveDownloadAction(_ label: String, id: GameID, expectedJobID: UUID? = nil) {
        guard let job = liveJob(for: id) else { return }
        guard expectedJobID == nil || expectedJobID == job.id else { return }
        if label == "Dismiss from history" {
            guard let reviewed = downloadHistoryReview, reviewed.id == job.id else { return }
            dismissDownloadHistory(reviewed); return
        }
        if label == "Open game" { openGame(game(for: job)); return }
        if label == "View logs" { show(.logs(id)); return }
        if label == "Cancel download…" || label == "Stop verifying…" { show(.confirmation(.cancelDownload(id))); return }
        guard let installQueue else { return }
        panel = nil
        Task { [weak self] in
            do {
                switch label {
                case "Pause": try await installQueue.setPaused(true, reason: .user, jobID: job.id)
                case "Resume":
                    for reason in job.pauseReasons where reason != .gameplay { try await installQueue.setPaused(false, reason: reason, jobID: job.id) }
                case "Retry": try await installQueue.retry(job.id)
                case "Retry cancellation": try await installQueue.cancel(job.id)
                case "Move up", "Move down":
                    guard let self else { return }
                    let queued = self.visibleInstallJobs.filter { $0.state == .queued }
                    guard let index = queued.firstIndex(where: { $0.id == job.id }) else { return }
                    if label == "Move up", index > 0 { try await installQueue.move(job.id, before: queued[index - 1].id) }
                    if label == "Move down", index + 1 < queued.count { try await installQueue.move(queued[index + 1].id, before: job.id) }
                default: break
                }
            } catch { self?.show(.information((error as? OperationFailure)?.reason ?? error.localizedDescription)) }
        }
    }
    func cancelLiveDownload(_ id: GameID) {
        guard let job = liveJob(for: id), let installQueue else { return }
        panel = nil
        Task { [weak self] in
            do { try await installQueue.cancel(job.id) }
            catch { self?.show(.information((error as? OperationFailure)?.reason ?? error.localizedDescription)) }
        }
    }
}
extension JobRecord {
    var displayProgress: Double {
        if kind == .uninstall { return state == .completed ? 1 : completedStages.contains(.removeBottle) ? 0.9 : completedStages.contains(.removeFiles) ? 0.6 : 0.1 }
        guard let bytesTotal, bytesTotal > 0 else { return 0 }; return min(1, max(0, Double(bytesCompleted) / Double(bytesTotal)))
    }
    var stageTitle: String {
        switch stage {
        case .resolve: "Checking game"; case .estimate: "Checking space"; case .reserve: "Reserving space"
        case .download: kind == .repair ? "Checking and repairing files" : "Downloading"; case .verifyOriginals, .validate: "Verifying files"; case .createBottle: "Preparing game runtime"
        case .prerequisites: "Installing prerequisites"; case .stage: "Preparing game"; case .commit: kind == .uninstall ? "Finishing removal" : "Finishing installation"
        case .finished: kind == .uninstall ? "Uninstalled" : kind == .repair ? "Files verified" : "Installed"; case .preserveSaves: "Checking saves"; case .removeFiles: "Removing game files"; case .removeBottle: "Removing game runtime"
        }
    }
    var statusTitle: String {
        switch state {
        case .queued: "Queued"; case .running: stageTitle; case .stopping: cancellationRequested == true ? "Cancelling…" : "Pausing…"
        case .paused: pauseReasons.contains(.authentication) ? "Sign in to resume" : pauseReasons.contains(.unavailableDrive) ? "Reconnect your games drive" : pauseReasons.contains(.insufficientSpace) ? "More space needed" : pauseReasons.contains(.user) ? "Paused" : "Paused while playing"
        case .failed: kind == .uninstall ? "Removal needs attention" : kind == .repair ? "Verification failed" : "Installation failed"; case .cancelled: kind == .repair ? "Verification stopped" : "Cancelled"; case .completed: kind == .uninstall ? "Uninstalled" : kind == .repair ? "Files verified" : "Installed"
        }
    }
    var bytesLabel: String {
        if kind == .uninstall { return state == .completed ? "Local files removed · Cloud saves kept" : "Game files, runtime and local saves" }
        let done = ByteCountFormatter.string(fromByteCount: bytesCompleted, countStyle: .file)
        return bytesTotal.map { done + " of " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " written" } ?? done + " written"
    }
}
