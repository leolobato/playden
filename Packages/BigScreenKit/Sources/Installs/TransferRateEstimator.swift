import Foundation
import Domain

public struct InstallTransferMetrics: Equatable, Sendable {
    public let bytesPerSecond: Double
    public let secondsRemaining: Double?
    public init(bytesPerSecond: Double, secondsRemaining: Double?) {
        self.bytesPerSecond = bytesPerSecond; self.secondsRemaining = secondsRemaining
    }
}

/// Ephemeral monotonic samples. Bytes reused from disk never contribute to either rate.
struct TransferRateEstimator {
    private struct Sample { let time: TimeInterval; let network: Int64; let written: Int64 }
    private var samples: [Sample]
    private var remaining: Int64 = 0
    private var supported = false
    private var displayedETA: Double?
    private var lastETAUpdate: TimeInterval?
    init(now: TimeInterval) { samples = [.init(time: now, network: 0, written: 0)] }
    mutating func record(_ progress: InstallProgress, now: TimeInterval) {
        guard let network = progress.downloadedBytes, let written = progress.freshlyWrittenBytes,
              let last = samples.last, now.isFinite, now >= last.time,
              network >= last.network, written >= last.written, progress.bytesCompleted >= 0,
              progress.bytesTotal >= progress.bytesCompleted else { return }
        supported = true; remaining = progress.bytesTotal - progress.bytesCompleted
        samples.append(.init(time: now, network: network, written: written))
        while samples.count > 2 && samples[1].time < now - 30 { samples.removeFirst() }
    }
    mutating func metrics(now: TimeInterval) -> InstallTransferMetrics? {
        guard supported, let latest = samples.last, now.isFinite,
              let start = samples.last(where: { $0.time <= now - 8 }) ?? samples.first,
              now - start.time >= 1 else { return nil }
        let elapsed = now - start.time
        let networkRate = Double(latest.network - start.network) / elapsed
        let longStart = samples.last(where: { $0.time <= now - 30 }) ?? samples[0]
        let longElapsed = now - longStart.time
        let writeRate = Double(latest.written - longStart.written) / max(1, longElapsed)
        // Network speed and completion speed use their own units (compressed body vs assembled data).
        // After a stall, stale positive rates disappear as the sampling window advances.
        if remaining <= 0 || writeRate <= 0 || networkRate <= 0 || longElapsed < 10 {
            displayedETA = nil; lastETAUpdate = nil
        } else if lastETAUpdate == nil || now - lastETAUpdate! >= 5 {
            let eta = Double(remaining) / writeRate
            displayedETA = eta.isFinite ? eta : nil; lastETAUpdate = now
        }
        return .init(bytesPerSecond: max(0, networkRate), secondsRemaining: displayedETA)
    }
}
