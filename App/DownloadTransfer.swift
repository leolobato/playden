import Foundation
import Domain

extension LibraryModel {
    func transferLabel(for job: JobRecord) -> String? {
        guard let speed = transferSpeedLabel(for: job) else { return nil }
        return [speed, transferTimeLabel(for: job)].compactMap { $0 }.joined(separator: " · ")
    }
    func transferSpeedLabel(for job: JobRecord) -> String? {
        guard job.id == activeInstallID, job.state == .running, job.stage == .download else { return nil }
        guard let rate = installTransfer else { return "Measuring speed…" }
        let formatter = ByteCountFormatter(); formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false
        let bytes = Int64(min(Double(Int64.max / 2), max(0, rate.bytesPerSecond.isFinite ? rate.bytesPerSecond : 0)))
        return formatter.string(fromByteCount: bytes) + "/s"
    }
    func transferTimeLabel(for job: JobRecord) -> String? {
        guard job.id == activeInstallID, job.state == .running, job.stage == .download,
              let seconds = installTransfer?.secondsRemaining, seconds.isFinite, seconds > 0 else { return nil }
        if seconds >= 86400 { return "More than a day left" }
        if seconds < 60 { return "Less than a minute left" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 60 { return "About \(minutes / 60) h \(minutes % 60) min left" }
        return "About \(minutes) min left"
    }
    func downloadStats(for job: JobRecord) -> String {
        [job.bytesLabel, transferLabel(for: job)].compactMap { $0 }.joined(separator: " · ")
    }
}
