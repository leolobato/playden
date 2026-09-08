import Foundation
import Domain

extension LibraryModel {
    func fileVerification(for job: JobRecord) -> InstallFileVerification? {
        guard job.id == activeInstallID, job.state == .running, job.stage == .download else { return nil }
        return installTransfer?.verification
    }
    func downloadStatusTitle(for job: JobRecord) -> String {
        fileVerification(for: job) == nil ? job.statusTitle : "Verifying file"
    }
    func downloadProgress(for job: JobRecord) -> Double {
        fileVerification(for: job)?.fraction ?? job.displayProgress
    }
    func downloadBytesLabel(for job: JobRecord) -> String {
        guard let check = fileVerification(for: job) else { return job.bytesLabel }
        let formatter = ByteCountFormatter(); formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: check.bytesChecked) + " of "
            + formatter.string(fromByteCount: check.bytesTotal) + " checked"
    }
    func transferLabel(for job: JobRecord) -> String? {
        guard let speed = transferSpeedLabel(for: job) else { return nil }
        return [speed, transferTimeLabel(for: job)].compactMap { $0 }.joined(separator: " · ")
    }
    func transferSpeedLabel(for job: JobRecord) -> String? {
        guard job.id == activeInstallID, job.state == .running, job.stage == .download else { return nil }
        guard fileVerification(for: job) == nil else { return nil }
        guard let rate = installTransfer else { return "Measuring…" }
        let formatter = ByteCountFormatter(); formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false
        let bytes = Int64(min(Double(Int64.max / 2), max(0, rate.bytesPerSecond.isFinite ? rate.bytesPerSecond : 0)))
        return formatter.string(fromByteCount: bytes) + "/s"
    }
    func transferTimeLabel(for job: JobRecord) -> String? {
        guard job.id == activeInstallID, job.state == .running, job.stage == .download,
              fileVerification(for: job) == nil,
              let seconds = installTransfer?.secondsRemaining, seconds.isFinite, seconds > 0 else { return nil }
        if seconds >= 86400 { return "More than a day left" }
        if seconds < 60 { return "Less than a minute left" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 60 { return "About \(minutes / 60) h \(minutes % 60) min left" }
        return "About \(minutes) min left"
    }
    func downloadStats(for job: JobRecord) -> String {
        [downloadBytesLabel(for: job), transferLabel(for: job)].compactMap { $0 }.joined(separator: " · ")
    }
}
