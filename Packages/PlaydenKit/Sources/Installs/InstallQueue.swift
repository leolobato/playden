import Foundation
import Domain
import Catalog
import Runner

public struct InstallQueueSnapshot: Sendable {
    public let jobs: [JobRecord]
    public let activeJobID: UUID?
    public let persistenceFailure: OperationFailure?
    public let transfer: InstallTransferMetrics?
    public let preparation: InstallPreparationProgress?
    public init(jobs: [JobRecord], activeJobID: UUID? = nil, persistenceFailure: OperationFailure? = nil, transfer: InstallTransferMetrics? = nil, preparation: InstallPreparationProgress? = nil) {
        self.jobs = jobs; self.activeJobID = activeJobID; self.persistenceFailure = persistenceFailure; self.transfer = transfer; self.preparation = preparation
    }
}
public struct InstallOffer: Sendable {
    public let plan: InstallPlan
    public let volume: GamesVolumeSelection
    public let freeBytes: Int64
    public let reservedBytes: Int64
    public init(plan: InstallPlan, volume: GamesVolumeSelection, freeBytes: Int64, reservedBytes: Int64) {
        self.plan = plan; self.volume = volume; self.freeBytes = freeBytes; self.reservedBytes = reservedBytes
    }
    public var availableBytes: Int64 { max(0, freeBytes - reservedBytes) }
    public var canInstall: Bool { plan.estimate.requiredBytes <= availableBytes }
}
public protocol InstallQueuing: Sendable {
    func start() async throws
    func shutdown() async
    func updates() async -> AsyncStream<InstallQueueSnapshot>
    func offer(for game: SourceGameRecord, volume: GamesVolumeSelection) async throws -> InstallOffer
    func enqueue(_ offer: InstallOffer) async throws -> UUID
    func repair(_ gameID: GameID) async throws -> UUID
    func uninstall(_ authorization: UninstallAuthorization) async throws -> UUID
    func setPaused(_ paused: Bool, reason: PauseReason, jobID: UUID) async throws
    func retry(_ jobID: UUID) async throws
    func cancel(_ jobID: UUID) async throws
    func move(_ jobID: UUID, before otherID: UUID) async throws
    func setGameplayPaused(_ paused: Bool) async throws
}

/// The sole writer of install-job state. UI tasks may subscribe or disconnect without owning work.
public actor InstallQueue: InstallQueuing {
    private let catalog: CatalogStore
    private let sources: [String: any GameSource]
    private let storage: any InstallStorageManaging
    private let bottles: any GameBottleManaging
    private var records: [UUID: JobRecord]
    private var observers: [UUID: AsyncStream<InstallQueueSnapshot>.Continuation] = [:]
    private var activeTask: Task<Void, Never>?
    private var activeID: UUID?
    private var activeRun: UUID?
    private var running = false
    private var startupID: UUID?
    private var persistenceFailure: OperationFailure?
    private var progressTime: TimeInterval = 0
    private var progressCompleted: Int64 = 0
    private var progressSequence: UInt64?
    private var preparationProgress: InstallPreparationProgress?
    private var stageVerification: InstallFileVerification?
    private var transferMeter: TransferRateEstimator?
    private var transferTicker: Task<Void, Never>?
    private var gameplayPaused = false
    private let stages: [JobStage] = [.reserve, .download, .verifyOriginals, .createBottle, .prerequisites, .stage, .validate, .commit]
    public init(catalog: CatalogStore, sources: [any GameSource], storage: any InstallStorageManaging = InstallStorage(),
                bottles: any GameBottleManaging = CrossOverGameBottles()) throws {
        self.catalog = catalog; self.storage = storage; self.bottles = bottles
        var registry: [String: any GameSource] = [:]
        for source in sources {
            guard registry.updateValue(source, forKey: source.id) == nil else { throw Self.failure("Source", "A store was registered more than once.") }
        }
        self.sources = registry
        records = Dictionary(uniqueKeysWithValues: try catalog.jobs().map { ($0.id, $0) })
    }
    public func snapshot() -> InstallQueueSnapshot {
        let downloading = activeID.flatMap { records[$0] }.map { $0.stage == .download && $0.state == .running } ?? false
        return .init(jobs: ordered, activeJobID: activeID, persistenceFailure: persistenceFailure,
            transfer: downloading ? transferMeter?.metrics(now: ProcessInfo.processInfo.systemUptime) :
                (activeID.flatMap { records[$0] }?.state == .running ? stageVerification.map {
                    InstallTransferMetrics(bytesPerSecond: 0, secondsRemaining: nil, verification: $0)
                } : nil), preparation: activeID.flatMap { records[$0] }.map { $0.stage == .stage && $0.state == .running } == true ? preparationProgress : nil)
    }
    public func updates() -> AsyncStream<InstallQueueSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation; continuation.yield(snapshot())
            continuation.onTermination = { @Sendable _ in Task { await self.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    public func start() async throws {
        guard !running else { return }
        guard startupID == nil else { throw Self.failure("Start queue", "The install queue is already starting.") }
        let startup = UUID(); startupID = startup
        defer { if startupID == startup { startupID = nil } }
        for var job in ordered where ![.completed, .cancelled].contains(job.state) {
            if job.state == .running || job.state == .stopping {
                job.state = job.pauseReasons.isEmpty || job.cancellationRequested == true ? .queued : .paused
                // Validation's result is not trusted across a process restart before the final commit.
                if job.kind != .uninstall { job.completedStages.remove(.validate); job.launchSpec = nil }
                try save(job)
            }
        }
        // Refresh older installs before opening the queue to new work. The bottle manager
        // refuses running games; disconnected drives and unfinished maintenance retry next start.
        let activeGames = Set(try catalog.unfinishedSessions().map(\.gameID))
        for entry in try catalog.snapshot().entries {
            guard startupID == startup else { throw CancellationError() }
            guard let installed = entry.installation, installed.needsRepair != true, !activeGames.contains(installed.gameID),
                  !ordered.contains(where: { $0.gameID == installed.gameID && ![.completed, .cancelled].contains($0.state) }) else { continue }
            do {
                let directory = try await storage.directory(installed.location, gameID: installed.gameID, owner: installed.ownershipToken)
                let bottle = GameBottle(gameID: installed.gameID, name: installed.bottleID, ownershipToken: installed.ownershipToken, templateVersion: installed.templateVersion)
                try await bottles.updatePresentation(bottle, title: installed.game.title, directory: directory, spec: installed.launchSpec)
            } catch {
                // Cosmetic integration must not prevent offline play or queue recovery.
                continue
            }
        }
        guard startupID == startup else { throw CancellationError() }
        running = true; pump()
    }
    public func shutdown() async {
        startupID = nil; running = false; activeTask?.cancel()
        await activeTask?.value
    }
    public func offer(for game: SourceGameRecord, volume: GamesVolumeSelection) async throws -> InstallOffer {
        guard let source = sources[game.id.source] else { throw Self.failure("Resolve", "This game's store is unavailable.") }
        let installer = try source.installer(for: game)
        let plan = try await installer.resolve()
        guard plan.game.id == game.id, installer.gameID == game.id else { throw Self.failure("Resolve", "The store returned a plan for a different game.") }
        return try await offer(plan: plan, volume: volume)
    }
    public func offer(plan: InstallPlan, volume: GamesVolumeSelection) async throws -> InstallOffer {
        try validateEstimate(plan.estimate)
        return InstallOffer(plan: plan, volume: volume, freeBytes: try await storage.freeBytes(on: volume), reservedBytes: reserved(on: volume.volumeID))
    }
    @discardableResult public func enqueue(_ offer: InstallOffer) async throws -> UUID {
        guard let source = sources[offer.plan.game.id.source] else { throw Self.failure("Queue", "This game's store is unavailable.") }
        _ = try source.installer(for: offer.plan.game)
        let checked = try await self.offer(plan: offer.plan, volume: offer.volume)
        try Task.checkCancellation()
        guard checked.canInstall else { throw Self.failure("Reserve space", "There is not enough free space after queued installations are reserved.") }
        let gameID = offer.plan.game.id
        guard !records.values.contains(where: { $0.gameID == gameID && ![.completed, .cancelled].contains($0.state) }),
              try !catalog.snapshot().entries.contains(where: { $0.id == gameID && $0.installation != nil }) else {
            throw Self.failure("Queue", "This game is already installed or has an unfinished job.")
        }
        var job = JobRecord(gameID: gameID, queuePosition: records.count)
        job.plan = offer.plan; job.volume = offer.volume; job.manifestIDs = offer.plan.manifestIDs
        job.bottle = GameBottle(gameID: gameID, name: CrossOverGameBottles.name(for: gameID), ownershipToken: job.ownershipToken)
        var location = GameLocation(volumeID: offer.volume.volumeID, rootBookmark: offer.volume.rootBookmark,
            lastKnownRoot: offer.volume.lastKnownRoot, relativePath: CrossOverGameBottles.name(for: gameID) + "/game")
        location.relativeRoot = offer.volume.relativeRoot; job.location = location
        job.bytesTotal = offer.plan.estimate.installedBytes; job.stage = .reserve; job.completedStages = [.resolve, .estimate]
        if gameplayPaused { job.pauseReasons.insert(.gameplay); job.state = .paused }
        try save(job); pump(); return job.id
    }
    public func setPaused(_ paused: Bool, reason: PauseReason = .user, jobID: UUID) throws {
        guard var job = records[jobID], ![.completed, .cancelled].contains(job.state), job.cancellationRequested != true else { return }
        guard job.kind != .uninstall else { throw Self.failure("Uninstall", "Removal continues until it finishes. Retry it if an error occurs.") }
        if paused { job.pauseReasons.insert(reason) } else { job.pauseReasons.remove(reason) }
        if !job.pauseReasons.isEmpty { job.state = activeID == jobID ? .stopping : .paused }
        else if job.state != .failed { job.state = activeID == jobID ? .running : .queued }
        try save(job)
        if !job.pauseReasons.isEmpty, activeID == jobID { activeTask?.cancel() }
        pump()
    }
    @discardableResult public func repair(_ gameID: GameID) throws -> UUID {
        guard let installed = try catalog.snapshot().entries.first(where: { $0.id == gameID })?.installation,
              let plan = installed.plan, let bookmark = installed.location.rootBookmark,
              let relativeRoot = installed.location.relativeRoot, let source = sources[gameID.source] else {
            throw Self.failure("Verify files", "The installed manifest or games drive is unavailable.")
        }
        _ = try source.installer(for: installed.game)
        var job = JobRecord(gameID: gameID, kind: .repair, queuePosition: records.count)
        job.originalInstallation = installed; job.plan = plan; job.staging = installed.staging
        job.ownershipToken = installed.ownershipToken; job.manifestIDs = installed.manifestIDs; job.location = installed.location
        job.bottle = GameBottle(gameID: gameID, name: installed.bottleID, ownershipToken: installed.ownershipToken, templateVersion: installed.templateVersion)
        job.volume = GamesVolumeSelection(volumeID: installed.location.volumeID, rootBookmark: bookmark,
            lastKnownRoot: installed.location.lastKnownRoot, relativeRoot: relativeRoot)
        job.bytesTotal = plan.estimate.installedBytes; job.stage = .download
        job.completedStages = [.resolve, .estimate, .reserve]
        if gameplayPaused { job.pauseReasons.insert(.gameplay); job.state = .paused }
        try catalog.enqueueRepair(job); records[job.id] = job; publish(); pump(); return job.id
    }
    public func setGameplayPaused(_ paused: Bool) async throws {
        gameplayPaused = paused
        for job in ordered where job.kind != .uninstall && ![.completed, .cancelled].contains(job.state) { try setPaused(paused, reason: .gameplay, jobID: job.id) }
        // Launching must wait for the download worker to release its files and runtime work.
        if paused { await activeTask?.value }
    }
    public func retry(_ jobID: UUID) throws {
        guard var job = records[jobID], job.state == .failed else { return }
        job.failure = nil; job.state = job.pauseReasons.isEmpty || job.cancellationRequested == true ? .queued : .paused
        if job.kind != .uninstall { job.completedStages.remove(.validate); job.launchSpec = nil }
        try save(job); pump()
    }
    public func cancel(_ jobID: UUID) throws {
        guard var job = records[jobID], ![.completed, .cancelled].contains(job.state) else { return }
        guard job.kind != .uninstall else { throw Self.failure("Uninstall", "This removal has already been confirmed. It must finish before the game can be reinstalled.") }
        job.cancellationRequested = true; job.state = activeID == jobID ? .stopping : .queued
        try save(job)
        if activeID == jobID { activeTask?.cancel() }
        pump()
    }
    public func move(_ jobID: UUID, before otherID: UUID) throws {
        guard jobID != activeID, let job = records[jobID], ![.completed, .cancelled].contains(job.state),
              let other = records[otherID], ![.completed, .cancelled].contains(other.state) else { return }
        var ids = ordered.map(\.id); ids.removeAll { $0 == jobID }
        guard let index = ids.firstIndex(of: otherID) else { return }; ids.insert(jobID, at: index)
        let jobs = ids.enumerated().compactMap { index, id -> JobRecord? in
            guard var value = records[id] else { return nil }; value.queuePosition = index; return value
        }
        try catalog.saveJobs(jobs)
        for value in jobs { records[value.id] = value }; publish()
    }
    private var ordered: [JobRecord] {
        records.values.sorted { $0.queuePosition == $1.queuePosition ? $0.createdAt < $1.createdAt : $0.queuePosition < $1.queuePosition }
    }
    private func reserved(on volumeID: String, excluding id: UUID? = nil) -> Int64 {
        InstallReservations.bytes(Array(records.values), on: volumeID, excluding: id)
    }
    private func pump() {
        guard running, persistenceFailure == nil, activeTask == nil,
              let job = ordered.first(where: { $0.state == .queued && ($0.pauseReasons.isEmpty || $0.cancellationRequested == true) }) else { return }
        let run = UUID(); activeRun = run; activeID = job.id; progressTime = 0
        activeTask = Task {
            await DiagnosticOutputContext.$sink.withValue(catalog.diagnosticSink(for: job.id)) {
                await self.execute(job.id, run: run)
            }
        }; publish()
    }
    private func execute(_ id: UUID, run: UUID) async {
        defer { transferTicker?.cancel(); transferTicker = nil; transferMeter = nil; stageVerification = nil; preparationProgress = nil; activeTask = nil; activeID = nil; activeRun = nil; publish(); pump() }
        do {
            if records[id]?.kind == .uninstall { try await executeUninstall(id); return }
            guard let initial = records[id], [.install, .repair].contains(initial.kind), let plan = initial.plan, let volume = initial.volume,
                  let bottle = initial.bottle, let source = sources[initial.gameID.source] else { throw Self.failure("Recover", "The saved installation plan or store is unavailable.") }
            guard plan.game.id == initial.gameID, bottle.gameID == initial.gameID, bottle.ownershipToken == initial.ownershipToken else {
                throw Self.failure("Recover", "The saved installation ownership does not match this job.")
            }
            let installer = try source.installer(for: plan.game)
            guard installer.gameID == initial.gameID else { throw Self.failure("Recover", "The installer's game identity does not match this job.") }
            if initial.cancellationRequested == true { try await cleanup(initial, installer: installer); return }
            if initial.completedStages.contains(.createBottle), try await !bottles.isReady(bottle) {
                try invalidateRuntimeStages(id)
            }
            for stage in stages {
                try checkpoint(id)
                guard var job = records[id] else { return }
                if job.completedStages.contains(stage) { continue }
                stageVerification = nil; preparationProgress = nil; progressTime = 0
                job.stage = stage; job.state = .running; try save(job)
                if [.prerequisites, .stage, .validate, .commit].contains(stage), try await !bottles.isReady(bottle) {
                    try invalidateRuntimeStages(id)
                    throw Self.failure("Game runtime", "The game's runtime is missing or incomplete. Retry to prepare it again.")
                }
                switch stage {
                case .reserve:
                    let free = try await storage.freeBytes(on: volume)
                    guard max(0, free - reserved(on: volume.volumeID, excluding: id)) >= max(0, plan.estimate.requiredBytes - job.bytesCompleted) else {
                        throw Self.failure("Reserve space", "There is not enough free space to continue this installation.")
                    }
                    let location = try await storage.prepare(gameID: job.gameID, owner: job.ownershipToken, on: volume)
                    try update(id) { $0.location = location }
                case .download:
                    let path = try await directory(job)
                    progressCompleted = 0; progressSequence = nil
                    transferMeter = TransferRateEstimator(now: ProcessInfo.processInfo.systemUptime)
                    transferTicker = Task {
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(1)) } catch { return }
                            guard self.activeRun == run, self.records[id]?.stage == .download else { return }
                            self.publish()
                        }
                    }
                    let report: @Sendable (InstallProgress) -> Void = { progress in Task { await self.progress(progress, id: id, run: run) } }
                    if job.kind == .repair { try await installer.repair(plan, at: path, staging: job.staging, progress: report) }
                    else { try await installer.download(plan, to: path, progress: report) }
                    try update(id) { $0.bytesCompleted = plan.estimate.installedBytes; $0.currentFile = nil }
                case .verifyOriginals:
                    let result = try await installer.verifyOriginals(plan, at: directory(job), staging: job.staging) { value in
                        Task { await self.verificationProgress(value, id: id, run: run, stage: .verifyOriginals) }
                    }
                    guard result.isValid else { throw Self.failure("Verify", "Downloaded game files are missing or damaged. Retry to repair the download.") }
                case .createBottle: try await bottles.prepare(bottle)
                case .prerequisites: try await installer.preparePrerequisites(plan, at: directory(job), in: bottle)
                case .stage:
                    let staging = try await installer.postInstall(plan, at: directory(job), in: bottle) { value in
                        Task { await self.preparationProgress(value, id: id, run: run) }
                    }
                    try update(id) { $0.staging = staging }
                case .validate:
                    guard let staging = job.staging else { throw Self.failure("Verify", "Game preparation has no saved receipt.") }
                    let launch = try await installer.validate(plan, at: directory(job), staging: staging) { value in
                        Task { await self.verificationProgress(value, id: id, run: run, stage: .validate) }
                    }
                    try update(id) { $0.launchSpec = launch }
                case .commit:
                    guard let location = job.location, let staging = job.staging, let launch = job.launchSpec else { throw Self.failure("Finish install", "The installation has not finished validation.") }
                    // Staging and launch validation are already checkpointed in the job. If
                    // acknowledgment or the installation commit fails, Retry resumes here.
                    try await bottles.updatePresentation(bottle, title: plan.game.title, directory: directory(job), spec: launch)
                    try await bottles.completeSourcePreparation(bottle)
                    var installation = InstallationRecord(game: plan.game, location: location, bottleID: bottle.name, ownershipToken: bottle.ownershipToken,
                        manifestIDs: plan.manifestIDs, language: plan.language, templateVersion: bottle.templateVersion, recipeVersion: plan.recipeVersion,
                        stagingVersion: staging.version, launchSpec: launch, installedBytes: plan.estimate.installedBytes)
                    installation.plan = plan; installation.staging = staging
                    if let original = job.originalInstallation, job.kind == .repair {
                        installation.id = original.id; installation.installedAt = original.installedAt
                        installation.needsRepair = false
                    }
                    job.state = .completed; job.stage = .finished; job.failure = nil
                    job.completedStages.formUnion([.commit, .finished]); job.updatedAt = .now
                    try catalog.commitInstallation(installation, completing: job)
                    records[id] = job; publish(); return
                default: break
                }
                try checkpoint(id)
                try update(id) { $0.completedStages.insert(stage) }
            }
        } catch {
            guard var job = records[id] else { return }
            if Task.isCancelled || error is CancellationError {
                job.state = job.cancellationRequested == true || !running || job.pauseReasons.isEmpty ? .queued : .paused
            } else if job.kind == .uninstall {
                job.failure = error as? OperationFailure ?? Self.failure("Uninstall", error.localizedDescription)
                job.state = .failed
            } else {
                job.failure = error as? OperationFailure ?? Self.failure(job.stage.rawValue, error.localizedDescription)
                if let source = error as? SourceFailure, [.expired, .signedOut, .credentialsRejected].contains(source) {
                    job.pauseReasons.insert(.authentication); job.state = .paused
                } else if (error as? POSIXError)?.code == .ENOSPC || (error as? CocoaError)?.code == .fileWriteOutOfSpace || (error as? OperationFailure)?.stage == "Reserve space" {
                    job.pauseReasons.insert(.insufficientSpace); job.state = .paused
                } else if (error as? OperationFailure)?.stage == "Games volume", job.kind != .uninstall {
                    job.pauseReasons.insert(.unavailableDrive); job.state = .paused
                } else { job.state = .failed }
                if job.stage == .verifyOriginals { job.completedStages.remove(.download) }
                if job.kind == .repair && job.stage == .validate {
                    job.completedStages.subtract([.download, .verifyOriginals, .stage, .validate])
                }
            }
            do { try save(job) } catch {
                persistenceFailure = Self.failure("Save queue", "Install progress could not be saved. Free up space and restart Playden to recover the last checkpoint.")
            }
        }
    }
    private func invalidateRuntimeStages(_ id: UUID) throws {
        try update(id) {
            $0.completedStages.subtract([.createBottle, .prerequisites, .stage, .validate])
            $0.launchSpec = nil
        }
    }
    private func cleanup(_ job: JobRecord, installer: any Installer) async throws {
        if job.kind == .repair {
            // Cancelling maintenance never uninstalls a game. needsRepair remains set until a
            // later verification completes, so partially repaired content cannot be launched.
            try update(job.id) { $0.state = .cancelled; $0.failure = nil; $0.pauseReasons = []; $0.updatedAt = .now }
            return
        }
        if job.completedStages.contains(.reserve), let plan = job.plan {
            try await installer.uninstall(plan, at: directory(job))
        }
        if let bottle = job.bottle, job.completedStages.contains(.createBottle) || stages.firstIndex(of: job.stage).map({ $0 >= 3 }) == true {
            try await bottles.remove(bottle)
        }
        if let location = job.location { try await storage.remove(location, gameID: job.gameID, owner: job.ownershipToken) }
        try update(job.id) { $0.state = .cancelled; $0.failure = nil; $0.pauseReasons = []; $0.updatedAt = .now }
    }
    private func directory(_ job: JobRecord) async throws -> URL {
        guard let location = job.location else { throw Self.failure("Storage", "The game's folder has not been reserved.") }
        return try await storage.directory(location, gameID: job.gameID, owner: job.ownershipToken)
    }
    private func preparationProgress(_ value: InstallPreparationProgress, id: UUID, run: UUID) {
        guard activeRun == run, let job = records[id], job.stage == .stage, job.state == .running,
              !job.completedStages.contains(.stage),
              preparationProgress.map({ value.sequence > $0.sequence }) ?? true else { return }
        preparationProgress = value
        switch value.step {
        case .verifying(let check): verificationProgress(check, id: id, run: run, stage: .stage)
        default: stageVerification = nil; publish()
        }
    }
    private func verificationProgress(_ value: InstallFileVerification, id: UUID, run: UUID, stage: JobStage) {
        guard activeRun == run, let job = records[id], job.stage == stage, job.state == .running,
              !job.completedStages.contains(stage), value.scope == .installation,
              value.bytesChecked >= 0, value.bytesTotal >= value.bytesChecked else { return }
        if let previous = stageVerification {
            guard value.bytesTotal == previous.bytesTotal, value.bytesChecked >= previous.bytesChecked else { return }
        }
        let first = stageVerification == nil
        stageVerification = value
        let now = ProcessInfo.processInfo.systemUptime
        if first || value.bytesChecked == value.bytesTotal || now - progressTime >= 0.25 {
            progressTime = now; publish()
        }
    }
    private func progress(_ value: InstallProgress, id: UUID, run: UUID) {
        guard activeRun == run, let job = records[id], job.stage == .download, job.state == .running,
              !job.completedStages.contains(.download),
              value.bytesCompleted >= 0, value.bytesTotal >= value.bytesCompleted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard value.bytesCompleted >= progressCompleted else { return }
        if let sequence = value.sequence {
            guard progressSequence.map({ sequence > $0 }) ?? true else { return }
            progressSequence = sequence
        }
        progressCompleted = value.bytesCompleted
        let previousVerification = transferMeter?.verification
        transferMeter?.record(value, now: now)
        let phaseChanged = (previousVerification == nil) != (value.verification == nil)
            || previousVerification?.file != value.verification?.file
        guard phaseChanged || now - progressTime >= 0.25 else { return }; progressTime = now
        do { try update(id) { $0.bytesCompleted = value.bytesCompleted; $0.bytesTotal = value.bytesTotal; $0.currentFile = value.currentFile } }
        catch { persistenceFailure = Self.failure("Save queue", "Install progress could not be saved."); activeTask?.cancel(); publish() }
    }
    private func checkpoint(_ id: UUID) throws {
        try Task.checkCancellation()
        guard let job = records[id], job.pauseReasons.isEmpty, job.cancellationRequested != true else { throw CancellationError() }
    }
    private func update(_ id: UUID, _ change: (inout JobRecord) -> Void) throws {
        guard var job = records[id] else { return }; change(&job); try save(job)
    }
    private func save(_ value: JobRecord) throws {
        var job = value; job.updatedAt = .now
        if job.kind == .uninstall, let expected = records[job.id] {
            job = try catalog.checkpointUninstall(expected, stage: job.stage, state: job.state,
                completedStages: job.completedStages, failure: job.failure)
            records[job.id] = job; publish(); return
        }
        try catalog.saveJob(job); records[job.id] = job; publish()
    }
    @discardableResult public func uninstall(_ authorization: UninstallAuthorization) async throws -> UUID {
        let installed = authorization.review.installation
        guard installed.bottleID == CrossOverGameBottles.name(for: installed.gameID),
              installed.location.relativePath == installed.bottleID + "/game" else {
            throw Self.failure("Uninstall", "This game's folder or runtime identity is invalid. Its files have been kept.")
        }
        let job = try catalog.beginUninstall(authorization, queuePosition: records.count)
        records[job.id] = job; publish(); pump(); return job.id
    }
    private func executeUninstall(_ id: UUID) async throws {
        guard let initial = records[id], let installed = initial.originalInstallation, let bottle = initial.bottle,
              initial.uninstallAuthorization?.review.installation == installed,
              bottle.name == CrossOverGameBottles.name(for: installed.gameID), bottle.gameID == installed.gameID,
              bottle.ownershipToken == installed.ownershipToken, initial.ownershipToken == installed.ownershipToken,
              initial.location == installed.location else { throw Self.failure("Uninstall", "The saved removal ownership does not match this game.") }
        for stage in [JobStage.removeFiles, .removeBottle, .commit] {
            try checkpoint(id)
            guard let current = records[id] else { return }
            if current.completedStages.contains(stage) { continue }
            try update(id) { $0.stage = stage; $0.state = .running; $0.failure = nil }
            try await bottles.checkRemoval(bottle, previousRuntime: catalog.latestRuntimeSession(for: installed.gameID)?.runtime)
            // Revalidate the durable reservation after any asynchronous runtime inspection.
            try update(id) { $0.state = .running }
            switch stage {
            case .removeFiles: try await storage.remove(installed.location, gameID: installed.gameID, owner: installed.ownershipToken)
            case .removeBottle: try await bottles.remove(bottle)
            case .commit:
                try await storage.verifyRemoved(installed.location, gameID: installed.gameID, owner: installed.ownershipToken)
                try await bottles.verifyRemoved(bottle)
                try checkpoint(id)
                guard let expected = records[id] else { return }
                let completed = try catalog.completeUninstall(expected)
                records[id] = completed; publish(); return
            default: break
            }
            try checkpoint(id)
            try update(id) { $0.completedStages.insert(stage) }
        }
    }
    private func publish() { let value = snapshot(); for observer in observers.values { observer.yield(value) } }
    private func validateEstimate(_ value: InstallEstimate) throws {
        guard value.downloadBytes >= 0, value.installedBytes >= 0, value.requiredBytes >= value.installedBytes else { throw Self.failure("Estimate", "The store returned an invalid space estimate.") }
    }
    private static func failure(_ stage: String, _ reason: String) -> OperationFailure { .init(stage: stage, reason: reason, output: reason) }
}
