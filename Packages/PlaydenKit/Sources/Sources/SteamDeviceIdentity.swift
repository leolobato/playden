import Foundation
import Domain
import SteamCore

/// Playden's Steam device, kept for the life of the install. Every CM logon presents the same identity,
/// as the real client does, instead of looking like a new anonymous client each time.
enum SteamDeviceIdentity {
    static let machineName = "Playden"
    static let current = load()

    static func load(root: URL = AppPaths.supportRoot()) -> CMDeviceIdentity {
        let file = root.appendingPathComponent("steam-device-id")
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           UUID(uuidString: saved) != nil {
            return CMDeviceIdentity(seed: saved, machineName: machineName)
        }
        let seed = UUID().uuidString
        // If saving fails, the identity still stays stable for this run of the app.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(seed.utf8).write(to: file, options: .atomic)
        return CMDeviceIdentity(seed: seed, machineName: machineName)
    }
}
