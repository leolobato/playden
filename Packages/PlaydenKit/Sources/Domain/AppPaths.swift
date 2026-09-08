import Foundation

public enum AppPaths {
    /// Reuse the complete pre-rename profile, including runtime receipts and save journals.
    /// Choosing one root avoids splitting an existing installation across two profiles.
    public static func supportRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let legacy = support.appendingPathComponent("Big Screen", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return legacy
        }
        return support.appendingPathComponent("Playden", isDirectory: true)
    }
}
