import Foundation
import Domain

/// Three-way content comparison. File times are for display/preservation, never conflict winners.
/// This is a reviewable plan; the coordinator must still hold the game lock, stage both copies,
/// verify the local preconditions and recheck the remote revision before applying any changes.
public enum CloudSyncPlanner {
    public static func plan(installationID: UUID, mapping: SaveMapping, localFiles: [CloudLocalFile],
                            remote: CloudFileList, baseline: CloudSyncBaseline?,
                            attachedAccountKey: String?) throws -> CloudSyncPlan {
        let paths = try CloudSavePaths(mapping: mapping)
        if let baseline {
            guard baseline.gameID == remote.gameID, baseline.accountKey == remote.accountKey else {
                throw saveFailure("Cloud history belongs to another account or game.")
            }
            guard remote.revision >= baseline.revision else { throw saveFailure("Steam returned an older Cloud revision. Retry before changing any saves.") }
        }
        let base = baseline.flatMap { value in
            value.installationID == installationID && value.mapping == mapping && attachedAccountKey == remote.accountKey ? value : nil
        }
        var local: [String: CloudLocalFile] = [:], current: [String: CloudFile] = [:], previous: [String: CloudFile] = [:]
        var locations: [String: CloudSavePath] = [:], names: [String: String] = [:]
        var decisions: [CloudSyncDecision] = []
        for file in localFiles {
            guard file.sha1.count == 20, file.bytes >= 0 else { throw saveFailure("A local Cloud save is missing its verified fingerprint.") }
            guard let name = try paths.remoteName(for: file.location) else { continue }
            let key = file.location.key
            guard local.updateValue(file, forKey: key) == nil else { throw saveFailure("Local Cloud saves have ambiguous filenames.") }
            locations[key] = file.location; names[key] = name
        }
        for file in remote.files {
            guard let location = try paths.localPath(for: file.name) else {
                decisions.append(.init(name: file.name, location: nil, action: .unavailable, local: nil, remote: file))
                continue
            }
            guard file.state != .present || (file.bytes >= 0 && file.sha1.count == 20) else { throw saveFailure("A Cloud save is missing its verified fingerprint.") }
            guard current.updateValue(file, forKey: location.key) == nil else { throw saveFailure("Multiple Cloud names resolve to the same local save.") }
            locations[location.key] = local[location.key]?.location ?? location; names[location.key] = file.name
        }
        for file in base?.files ?? [] {
            guard let location = try paths.localPath(for: file.name), file.state == .present,
                  file.bytes >= 0, file.sha1.count == 20,
                  previous.updateValue(file, forKey: location.key) == nil else {
                throw saveFailure("The Cloud sync baseline is invalid. Existing saves have been kept.")
            }
            if locations[location.key] == nil { locations[location.key] = local[location.key]?.location ?? location; names[location.key] = file.name }
        }
        for key in locations.keys.sorted() {
            let here = local[key], there = current[key], before = previous[key]
            let localHash = here.map { Fingerprint(sha1: $0.sha1, bytes: $0.bytes) }
            let remoteHash = fingerprint(there), baseHash = fingerprint(before)
            let action: CloudSyncDecision.Action
            if there?.state == .forgotten {
                // Forgotten is not an explicit deletion. Do not erase local progress on that signal.
                action = .unavailable
            } else if localHash == remoteHash {
                action = there?.requiresUpload == true && here != nil ? .upload : .unchanged
            } else if base != nil {
                if localHash == baseHash { action = there?.state == .present ? .download : .deleteLocal }
                else if remoteHash == baseHash { action = here == nil ? .deleteRemote : .upload }
                else { action = .conflict }
            } else if here != nil && there?.state == .present {
                action = .conflict
            } else if here != nil && there?.state == .deleted {
                // A first-sync tombstone cannot prove whether this local save predates the deletion.
                action = .conflict
            } else {
                action = here == nil ? .download : .upload
            }
            decisions.append(.init(name: names[key]!, location: locations[key], action: action, local: here, remote: there))
        }
        let mutatesRemote = decisions.contains { [.upload, .deleteRemote].contains($0.action) }
        return CloudSyncPlan(gameID: remote.gameID, installationID: installationID, accountKey: remote.accountKey,
            remoteRevision: remote.revision, decisions: decisions.sorted { $0.name < $1.name },
            requiresAccountConfirmation: (mutatesRemote || !local.isEmpty) && attachedAccountKey != remote.accountKey)
    }
    private struct Fingerprint: Equatable { let sha1: Data; let bytes: Int64 }
    private static func fingerprint(_ file: CloudFile?) -> Fingerprint? {
        file.flatMap { $0.state == .present ? Fingerprint(sha1: $0.sha1, bytes: $0.bytes) : nil }
    }
}
