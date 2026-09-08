import Foundation
import Domain

/// CDN responses arrive concurrently. Publish cumulative counters with one consistent snapshot.
final class SteamTransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let report: @Sendable (InstallProgress) -> Void
    private var downloaded: Int64 = 0, completed: Int64 = 0
    private var written: [UInt32: Int64] = [:]
    private var file = ""
    private var verification: InstallFileVerification?
    private var sequence: UInt64 = 0
    init(total: Int64, report: @escaping @Sendable (InstallProgress) -> Void) { self.total = total; self.report = report }
    func received(_ count: Int) {
        lock.lock()
        downloaded = Self.add(downloaded, max(0, Int64(count)))
        let value = snapshot(); lock.unlock(); report(value)
    }
    func assembled(depot: UInt32, completed: Int64, fresh: Int64?, file: String, verification: InstallFileVerification? = nil) {
        lock.lock()
        self.completed = max(self.completed, completed); self.file = file; self.verification = verification
        if let fresh { written[depot] = max(written[depot, default: 0], fresh) }
        let value = snapshot(); lock.unlock(); report(value)
    }
    private func snapshot() -> InstallProgress {
        sequence += 1
        return .init(bytesCompleted: completed, bytesTotal: total, currentFile: file, downloadedBytes: downloaded,
            freshlyWrittenBytes: written.values.reduce(0, Self.add), verification: verification, sequence: sequence)
    }
    private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let result = a.addingReportingOverflow(b); return result.overflow ? .max : result.partialValue
    }
}
