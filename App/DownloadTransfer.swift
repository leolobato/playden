import Foundation
import Domain

extension LibraryModel {
    func fileVerification(for job: JobRecord) -> InstallFileVerification? {
        guard job.id == activeInstallID, job.state == .running, [.download, .verifyOriginals, .stage, .validate].contains(job.stage) else { return nil }
        return installTransfer?.verification
    }
    func downloadStatusTitle(for job: JobRecord) -> String {
        guard let check = fileVerification(for: job) else {
            if job.id == activeInstallID, job.state == .running, job.stage == .stage {
                switch installPreparation?.step {
                case .preparingExecutable: return "Preparing executable"
                case .applyingSettings: return "Applying game settings"
                default: break
                }
            }
            return job.statusTitle
        }
        if job.stage == .stage { return "Checking files before setup" }
        return check.scope == .installation ? "Verifying files" : "Verifying file"
    }
    func downloadProgress(for job: JobRecord) -> Double {
        if let check = fileVerification(for: job) { return check.fraction }
        return job.state == .running && [.verifyOriginals, .stage, .validate].contains(job.stage) ? 0 : job.displayProgress
    }
    func downloadPercentage(for job: JobRecord) -> String? {
        guard job.id == activeInstallID, job.state == .running else { return nil }
        if let check = fileVerification(for: job) {
            guard check.bytesTotal > 0 else { return nil }
        } else if job.stage != .download { return nil }
        // Do not round an unfinished verification up to 100%.
        return (floor(downloadProgress(for: job) * 100) / 100).formatted(.percent.precision(.fractionLength(0)))
    }
    func downloadBytesLabel(for job: JobRecord) -> String {
        guard let check = fileVerification(for: job) else {
            return job.state == .running && [.verifyOriginals, .stage, .validate].contains(job.stage) ? (job.stage == .stage ? "Preparing game files…" : "Checking files…") : job.bytesLabel
        }
        let formatter = ByteCountFormatter(); formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: check.bytesChecked) + " of "
            + formatter.string(fromByteCount: check.bytesTotal) + " checked"
    }
    func preparationDetail(for job: JobRecord) -> String? {
        guard job.id == activeInstallID, job.state == .running, job.stage == .stage else { return nil }
        switch installPreparation?.step {
        case .verifying(let check): return check.file.isEmpty ? "Checking downloaded files before applying game setup." : check.file
        case .preparingExecutable(let path): return "Preparing executable · \(path)"
        case .applyingSettings: return "Applying game settings…"
        case nil: return "Checking downloaded files before applying game setup…"
        }
    }
    func downloadActivityDetail(for job: JobRecord) -> String {
        if let detail = preparationDetail(for: job) { return detail }
        if let file = fileVerification(for: job)?.file, !file.isEmpty { return file }
        return job.currentFile ?? "Your game will be ready after verification and setup."
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
