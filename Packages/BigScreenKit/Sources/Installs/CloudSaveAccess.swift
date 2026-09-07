import Foundation
import Domain
import Catalog
import Runner

/// Production root access for CloudSyncService. This never creates a bottle or stops a process.
/// It combines the existing ownership checks with the active journal claim and fresh writer
/// inspection; the SaveStore subsequently opens every path component without following links.
public struct CloudSaveAccess: Sendable {
    private let catalog: CatalogStore
    private let storage: any InstallStorageManaging
    private let bottles: any GameBottleManaging
    private let inspector: any RuntimeInspecting

    public init(catalog: CatalogStore, storage: any InstallStorageManaging = InstallStorage(),
                bottles: any GameBottleManaging = CrossOverGameBottles(),
                inspector: any RuntimeInspecting = RuntimeProcessInspector()) {
        self.catalog = catalog; self.storage = storage; self.bottles = bottles; self.inspector = inspector
    }

    public func roots(for installation: InstallationRecord) async throws -> [SaveRoot: URL] {
        guard let current = try catalog.snapshot().entries.first(where: { $0.id == installation.gameID })?.installation,
              current == installation, current.needsRepair != true else { throw issue("This installation changed. Retry save sync after verifying its files.") }
        let claims = try catalog.cloudOperations(for: installation.gameID).filter { !$0.phase.isTerminal && $0.claim != nil }
        guard claims.count == 1, let claim = claims.first,
              claim.installationID == installation.id, claim.ownershipToken == installation.ownershipToken else {
            throw issue("Save sync does not own this game's files. Retry after the current operation finishes.")
        }
        try verifySession(claim, installation: installation)
        let bottle = GameBottle(gameID: installation.gameID, name: installation.bottleID,
            ownershipToken: installation.ownershipToken, templateVersion: installation.templateVersion)
        let gameRoot = try await storage.directory(installation.location, gameID: installation.gameID, owner: installation.ownershipToken)
        let bottleRoot = try await bottles.ownedDirectory(bottle)
        try Task.checkCancellation()
        let observation = try inspector.inspect(bottle: bottleRoot)
        guard !observation.processes.contains(where: { $0.kind == .game || $0.kind == .wrapper }) else {
            throw issue("A game or launcher is still using these saves. Close it before syncing.")
        }
        // Inspection can omit a live process temporarily. Its birth identity, not just its PID,
        // remains authoritative. Unrelated unreadable system processes do not block Cloud.
        if let previous = try catalog.latestRuntimeSession(for: installation.gameID)?.runtime,
           previous.run.bottle.name == bottle.name, previous.run.bottle.ownershipToken == bottle.ownershipToken {
            let writers = Set(previous.processes.filter { $0.kind == .game || $0.kind == .wrapper }.map(\.identity) + [previous.run.launcher])
            for writer in writers {
                let identity = inspector.identity(of: writer.pid)
                if identity == writer || (identity == nil && observation.unreadablePIDs.contains(writer.pid)) {
                    throw issue("The previous game process has not been confirmed stopped. Retry save sync in a moment.")
                }
            }
        }
        // Ownership lookups can suspend. Reject a stale worker before returning paths to it.
        guard try catalog.cloudOperations(for: installation.gameID).contains(claim) else {
            throw issue("Save sync changed while checking its folders. Retry the current operation.")
        }
        try verifySession(claim, installation: installation)
        return [.game: gameRoot, .bottle: bottleRoot]
    }

    private func verifySession(_ claim: CloudSyncOperation, installation: InstallationRecord) throws {
        let active = try catalog.unfinishedSessions().filter { $0.gameID == installation.gameID }
        if let owner = claim.preparingSessionID {
            guard active.count == 1, active[0].id == owner, active[0].bottleID == installation.bottleID,
                  active[0].runtime == nil || active[0].runtime?.phase == .exited else {
                throw issue("The game session is still using its saves. Wait for it to finish.")
            }
        } else if !active.isEmpty { throw issue("A game session owns these saves. Wait for it to finish.") }
    }

    private func issue(_ message: String) -> OperationFailure { .init(stage: "Cloud saves", reason: message, output: "") }
}
