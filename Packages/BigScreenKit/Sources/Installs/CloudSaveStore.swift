import Foundation
import Darwin
import CryptoKit
import Domain

extension SaveStore {
    public func verifyCloudRoots(_ localSnapshotID: UUID, gameID: GameID, roots: [SaveRoot: URL]) throws {
        let local = try verified(localSnapshotID, gameID: gameID)
        try verifyCloudRoots(local, in: open(roots))
    }

    private func verifyCloudRoots(_ local: SaveSnapshot, in roots: [SaveRoot: SaveDirectory]) throws {
        // Legacy interrupted publications still use their content preconditions; new reviews
        // additionally refuse to apply authorization to replacement physical directories.
        if let expected = local.rootIdentities, try identities(local.mapping, in: roots) != expected {
            throw saveFailure("The save folder was replaced after review. Both staged copies have been kept.")
        }
    }

    /// Publish a complete downloaded set under an immutable ID before the journal permits any
    /// replacement. Payloads are rehashed here even when the transport has already verified them.
    public func stageCloud(_ remote: CloudFileList, installationID: UUID, mapping: SaveMapping,
                           downloads: [CloudUpload], id: UUID = UUID()) throws -> SaveSnapshot {
        let paths = try CloudSavePaths(mapping: mapping)
        try validate(mapping)
        guard !remote.accountKey.isEmpty, remote.files.count <= 100_000,
              Set(remote.files.map { $0.name.lowercased() }).count == remote.files.count,
              Set(downloads.map { $0.file.name }).count == downloads.count else { throw saveFailure("The downloaded save list is invalid.") }
        let payloads = Dictionary(uniqueKeysWithValues: downloads.map { ($0.file.name, $0) })
        let present = remote.files.filter { $0.state == .present }.sorted { $0.name < $1.name }
        guard Set(payloads.keys) == Set(present.map(\.name)) else { throw saveFailure("Not every Cloud save has finished downloading.") }
        var total: Int64 = 0
        for payload in downloads {
            total += Int64(payload.data.count)
            guard total <= 512 * 1024 * 1024 else { throw saveFailure("This Cloud save set exceeds the supported staging size.") }
        }
        var locations = Set<String>(), entries: [SavedFile] = []
        for file in remote.files {
            guard file.state != .forgotten, let location = try paths.localPath(for: file.name),
                  locations.insert(location.key).inserted else { throw saveFailure("A Cloud save location is unavailable or ambiguous.") }
        }
        for file in present {
            guard let upload = payloads[file.name], upload.file == file, upload.data.count <= 64 * 1024 * 1024,
                  Int64(upload.data.count) == file.bytes, Data(Insecure.SHA1.hash(data: upload.data)) == file.sha1,
                  let location = try paths.localPath(for: file.name), file.modifiedAt.timeIntervalSince1970.isFinite,
                  file.modifiedAt.timeIntervalSince1970 >= 0, file.modifiedAt.timeIntervalSince1970 < 253_402_300_800 else {
                throw saveFailure("A downloaded Cloud save failed verification.")
            }
            entries.append(.init(root: location.root, path: location.path, modifiedAt: file.modifiedAt,
                                 bytes: file.bytes, sha256: Data(SHA256.hash(data: upload.data)), sha1: file.sha1))
        }
        let store = try gameDirectory(remote.gameID, create: true)
        if try store.info(id.uuidString) != nil {
            let existing = try verified(id, gameID: remote.gameID)
            guard existing.installationID == installationID, existing.mapping == mapping,
                  existing.cloud == remote, existing.files == entries else { throw saveFailure("This staged save belongs to another Cloud attempt.") }
            return existing
        }
        let temporary = ".partial-\(UUID().uuidString)"
        guard mkdirat(store.fd, temporary, 0o700) == 0, let staging = try store.directory(temporary) else { throw SaveDirectory.posix() }
        var published = false
        defer { if !published { try? store.discardStaging(temporary) } }
        for (index, file) in present.enumerated() {
            try Task.checkCancellation()
            try staging.write(payloads[file.name]!.data, to: "files/\(index)")
        }
        var snapshot = SaveSnapshot(version: 1, id: id, gameID: remote.gameID, installationID: installationID,
                                    createdAt: .now, mapping: mapping, files: entries)
        snapshot.cloud = remote
        try staging.write(JSONEncoder().encode(snapshot), to: "manifest.json")
        try verifyFiles(snapshot, in: staging)
        guard fsync(staging.fd) == 0,
              renameatx_np(store.fd, temporary, store.fd, id.uuidString, UInt32(RENAME_EXCL)) == 0,
              fsync(store.fd) == 0 else { throw SaveDirectory.posix() }
        published = true
        return snapshot
    }

    /// Read verified immutable bytes for a Cloud upload or conflict choice, never a live save.
    public func stagedContents(_ id: UUID, gameID: GameID, location: CloudSavePath) throws -> Data {
        let snapshot = try verified(id, gameID: gameID)
        guard let index = snapshot.files.firstIndex(where: { CloudSavePath(root: $0.root, path: $0.path).key == location.key }),
              let archive = try gameDirectory(gameID).directory(id.uuidString),
              let file = try archive.file("files/\(index)") else { throw saveFailure("The staged save is unavailable.") }
        let bytes = try file.contents(maximum: 64 * 1024 * 1024), entry = snapshot.files[index]
        guard Int64(bytes.count) == entry.bytes, Data(SHA256.hash(data: bytes)) == entry.sha256,
              Data(Insecure.SHA1.hash(data: bytes)) == entry.sha1 else { throw saveFailure("The staged save changed before it could be read.") }
        return bytes
    }

    /// The coordinator must hold the Catalog Cloud claim, verify game/bottle ownership, stop the
    /// game writer and persist markCloudApplying BEFORE this call. Account consent and remote
    /// revision checks belong to that coordinator. Both snapshots remain intact after success.
    ///
    /// Every mapped live file is checked before the first mutation. On retry each file may match
    /// the reviewed original or the intended result, allowing recovery after any file boundary.
    /// A third fingerprint/new filename aborts rather than silently overwriting new progress.
    public func applyCloud(_ plan: CloudSyncPlan, localSnapshotID: UUID, remoteSnapshotID: UUID,
                           roots: [SaveRoot: URL],
                           onFileApplied: @Sendable (Int, Int) throws -> Void = { _, _ in }) throws -> [CloudLocalFile] {
        let (local, operations) = try cloudContext(plan, localSnapshotID: localSnapshotID, remoteSnapshotID: remoteSnapshotID)
        let destinations = try open(roots)
        try verifyCloudRoots(local, in: destinations)
        let cloudMapping = SaveMapping(rules: local.mapping.rules.filter { $0.cloudPrefix != nil }, coverage: local.mapping.coverage)
        func currentFiles() throws -> [String: SaveDigest] {
            var result: [String: SaveDigest] = [:]
            for location in try select(cloudMapping, in: destinations) {
                guard let file = try destinations[location.root]?.file(location.path) else { throw saveFailure("A local save disappeared during sync.") }
                result[location.key] = try file.stream()
            }
            return result
        }
        let current = try currentFiles(), keys = Set(operations.map { $0.location.key })
        guard Set(current.keys).isSubset(of: keys) else { throw saveFailure("New local saves appeared after review. Both staged copies have been kept.") }
        for change in operations {
            let actual = current[change.location.key]
            guard actual == change.before.map(digest) || actual == change.after.map(digest) else {
                throw saveFailure("Local progress changed after the Cloud review. Both staged copies have been kept.")
            }
        }
        guard let archive = try gameDirectory(plan.gameID).directory(remoteSnapshotID.uuidString) else { throw saveFailure("The Cloud staging copy is unavailable.") }
        for (index, change) in operations.enumerated() {
            try Task.checkCancellation()
            guard let destination = destinations[change.location.root] else { throw saveFailure("A save destination is unavailable.") }
            let source = try change.downloadIndex.flatMap { try archive.file("files/\($0)") }
            let after = change.after.map(digest)
            try destination.changeCloudFile(change.location.path, expected: change.before.map(digest), desired: after,
                temporary: cloudTemporary(remoteSnapshotID, location: change.location)) { descriptor in
                guard let entry = change.after, let source,
                      try source.stream({ try SaveDirectory.writeAll($0, to: descriptor) }) == after else {
                    throw saveFailure("The downloaded save changed before replacement.")
                }
                try Self.setSaveTime(entry.modifiedAt, descriptor: descriptor)
            }
            try onFileApplied(index + 1, operations.count)
        }
        let result = try currentFiles()
        let expected = Dictionary(uniqueKeysWithValues: operations.compactMap { change in
            change.after.map { (change.location.key, digest($0)) }
        })
        guard result == expected else { throw saveFailure("The final local save set changed during verification. Both staged copies have been kept.") }
        return try operations.compactMap { change in
            guard change.after != nil else { return nil }
            guard let file = try destinations[change.location.root]?.file(change.location.path),
                  let hash = result[change.location.key], try file.stream() == hash else {
                throw saveFailure("A local save changed at the end of sync. Both staged copies have been kept.")
            }
            return CloudLocalFile(location: change.location, sha1: hash.sha1, bytes: hash.bytes, modifiedAt: file.modifiedAt)
        }
    }

    struct CloudChange {
        let location: CloudSavePath
        let before: SavedFile?
        let after: SavedFile?
        let downloadIndex: Int?
    }
    func cloudContext(_ plan: CloudSyncPlan, localSnapshotID: UUID, remoteSnapshotID: UUID) throws -> (SaveSnapshot, [CloudChange]) {
        guard !plan.hasConflicts, !plan.hasUnavailableFiles, localSnapshotID != remoteSnapshotID else {
            throw saveFailure("Resolve the Cloud save conflict before replacing files.")
        }
        let local = try verified(localSnapshotID, gameID: plan.gameID)
        let downloaded = try verified(remoteSnapshotID, gameID: plan.gameID)
        guard local.cloud == nil, local.installationID == plan.installationID,
              downloaded.installationID == plan.installationID, local.mapping == downloaded.mapping,
              let remote = downloaded.cloud, remote.gameID == plan.gameID, remote.accountKey == plan.accountKey,
              remote.revision == plan.remoteRevision else { throw saveFailure("The staged saves do not match this account, installation and review.") }
        return (local, try cloudChanges(plan, local: local, downloaded: downloaded, paths: CloudSavePaths(mapping: local.mapping)))
    }
    private func cloudChanges(_ plan: CloudSyncPlan, local: SaveSnapshot, downloaded: SaveSnapshot,
                              paths: CloudSavePaths) throws -> [CloudChange] {
        var originals: [String: SavedFile] = [:], downloads: [String: Int] = [:]
        for entry in local.files {
            let location = CloudSavePath(root: entry.root, path: entry.path)
            if try paths.remoteName(for: location) != nil { originals[location.key] = entry }
        }
        for (index, entry) in downloaded.files.enumerated() { downloads[CloudSavePath(root: entry.root, path: entry.path).key] = index }
        let remoteFiles = downloaded.cloud!.files
        guard Set(remoteFiles.map(\.name)).count == remoteFiles.count,
              Set(plan.decisions.map(\.name)).count == plan.decisions.count else { throw saveFailure("The Cloud review contains duplicate filenames.") }
        let remote = Dictionary(uniqueKeysWithValues: remoteFiles.map { ($0.name, $0) })
        var seen = Set<String>(), seenRemote = Set<String>(), changes: [CloudChange] = []
        for decision in plan.decisions {
            guard let location = decision.location, try paths.localPath(for: decision.name)?.key == location.key,
                  seen.insert(location.key).inserted, remote[decision.name] == decision.remote else { throw saveFailure("The Cloud review does not match its staged copies.") }
            if decision.remote != nil { seenRemote.insert(decision.name) }
            let original = originals[location.key], downloadIndex = downloads[location.key]
            let download = downloadIndex.map { downloaded.files[$0] }
            if let original, location != CloudSavePath(root: original.root, path: original.path) {
                throw saveFailure("The Cloud review changed an existing local filename.")
            }
            guard original.map({ CloudLocalFile(location: .init(root: $0.root, path: $0.path), sha1: $0.sha1, bytes: $0.bytes, modifiedAt: $0.modifiedAt) }) == decision.local,
                  decision.remote?.state != .present || (download?.sha1 == decision.remote?.sha1 && download?.bytes == decision.remote?.bytes) else {
                throw saveFailure("A staged save differs from the reviewed fingerprint.")
            }
            let after: SavedFile?
            switch decision.action {
            case .upload:
                guard original != nil else { throw saveFailure("The local upload copy is missing.") }
                after = original
            case .download:
                guard let download, decision.remote?.state == .present else { throw saveFailure("The downloaded save is missing.") }
                after = download
            case .deleteLocal:
                guard decision.remote?.state != .present else { throw saveFailure("A save deletion contradicts the Cloud review.") }
                after = nil
            case .deleteRemote:
                guard original == nil else { throw saveFailure("A remote deletion contradicts the local save copy.") }
                after = nil
            case .unchanged:
                guard original.map(digest) == download.map(digest) else { throw saveFailure("The unchanged save copies differ.") }
                after = original
            case .conflict, .unavailable: throw saveFailure("The Cloud review still needs attention.")
            }
            changes.append(.init(location: location, before: original, after: after,
                                 downloadIndex: decision.action == .download ? downloadIndex : nil))
        }
        guard Set(originals.keys).isSubset(of: seen), seenRemote == Set(remote.keys) else {
            throw saveFailure("The Cloud review omitted a staged save.")
        }
        return changes.sorted { $0.location.key < $1.location.key }
    }
    private func cloudTemporary(_ snapshotID: UUID, location: CloudSavePath) -> String {
        let hash = Array(SHA256.hash(data: Data((snapshotID.uuidString + ":" + location.key).utf8)))
        let id = UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                             hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
        return ".bigscreen-cloud-\(id.uuidString).tmp"
    }
    private static func setSaveTime(_ time: Date, descriptor: Int32) throws {
        let seconds = time.timeIntervalSince1970, whole = floor(seconds)
        guard seconds.isFinite, seconds >= 0, seconds < 253_402_300_800 else { throw saveFailure("The Cloud save timestamp is invalid.") }
        var times = [timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1e9)),
                     timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1e9))]
        guard futimens(descriptor, &times) == 0 else { throw SaveDirectory.posix() }
    }
}
