import Foundation

public enum AppPaths {
    public static func supportRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Playden", isDirectory: true)
    }
}
