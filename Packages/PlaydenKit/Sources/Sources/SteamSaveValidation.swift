import Foundation
import CryptoKit
import Domain

/// Validate only the immutable local payload selected by CloudSyncService. The caller supplies
/// the latest actual writer session, not a newer pre-launch reservation with no runtime receipt.
public enum SteamSaveValidation {
    public static func validate(_ installation: InstallationRecord, uploads: [CloudUpload], deleting: [String],
                                previousSession: PlaySessionRecord?) throws {
        guard installation.gameID.source == "steam" else { throw failure("This store's save validation is unavailable.") }
        let clean: Bool
        if let previousSession, previousSession.gameID == installation.gameID, let runtime = previousSession.runtime {
            clean = runtime.run.bottle.ownershipToken == installation.ownershipToken &&
                runtime.run.bottle.name == installation.bottleID && runtime.phase == .exited &&
                runtime.hadWindow && runtime.exitCode == 0 && !runtime.forced &&
                (previousSession.outcome == nil || previousSession.outcome == .clean)
        } else { clean = false }
        guard deleting.isEmpty || clean else {
            throw failure("These save deletions followed an unexpected or unverified exit. Your Cloud copies have been kept. Play the game and quit normally before retrying.")
        }
        for upload in uploads {
            try Task.checkCancellation()
            guard upload.file.state == .present, upload.file.bytes == upload.data.count,
                  upload.data.count <= 64 * 1024 * 1024,
                  upload.file.sha1 == Data(Insecure.SHA1.hash(data: upload.data)) else {
                throw failure("The staged save failed its size or checksum check. Both copies have been kept; retry save sync.")
            }
            if installation.gameID.value == "1055540" {
                let name = upload.file.name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
                guard name.lowercased().hasSuffix(".mountain") else { throw failure("This A Short Hike save filename is unsupported. Your copies have been kept.") }
                do { try ShortHikeSaveValidator.validate(upload.data, filename: name) }
                catch is CancellationError { throw CancellationError() }
                catch { throw failure("A Short Hike's save is incomplete or uses an unsupported structure. Your Cloud copy has been kept. Load the game and save normally before retrying.") }
            } else if !clean {
                throw failure("This game's saves need validation after an unexpected or unverified exit. Your Cloud copies have been kept. Play the game and quit normally before retrying.")
            }
        }
    }
    private static func failure(_ message: String) -> OperationFailure { .init(stage: "Validate saves", reason: message, output: "") }
}
