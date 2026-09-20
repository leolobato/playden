import Foundation
import Synchronization
import OSLog
import Domain
import SteamCore

/// Release diagnostics also cover resolution before an install job exists. Only fixed stage
/// names, random operation IDs, public app IDs and numeric results belong in this log.
final class SteamConnectionDiagnostics: Sendable {
    static let shared = SteamConnectionDiagnostics(root: AppPaths.supportRoot().appendingPathComponent("logs"))
    private let lock = Mutex(())
    private let root: URL
    private let limit: Int
    private let logger = Logger(subsystem: "Playden", category: "SteamConnection")
    init(root: URL, limit: Int = 1_048_576) { self.root = root; self.limit = limit }

    func record(_ message: String) {
        lock.withLock { _ in
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let file = root.appendingPathComponent("steam-connections.log")
                let previous = root.appendingPathComponent("steam-connections.previous.log")
                let data = Data("\(Date.now.ISO8601Format()) \(DiagnosticRedactor.redact(message))\n".utf8)
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size + data.count > limit {
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.moveItem(at: file, to: previous) }
                }
                if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                logger.error("Could not write Steam connection diagnostics; code=\((error as NSError).code)")
            }
        }
    }

    // Never stringify arbitrary errors: HTTP URLs, server messages and credential errors
    // may contain secrets even when they do not use a recognizable key=value format.
    static func summary(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? URLError { return "network code=\(error.code.rawValue)" }
        if let error = error as? SteamError {
            switch error {
            case .eresult(let result, _): return "Steam result=\(result.rawValue)"
            case .http(let status, _): return "HTTP status=\(status)"
            case .authFailed: return "credentials rejected"
            case .authSessionExpired: return "session expired"
            case .notLoggedIn: return "signed out"
            case .protocolError: return "protocol error"
            case .crypto: return "crypto error"
            case .download: return "download error"
            case .prepare: return "preparation error"
            }
        }
        if let failure = error as? SourceFailure {
            if case .storage = failure { return "credential storage error" }
            return failure.localizedDescription
        }
        return "operation error code=\((error as NSError).code)"
    }
}
