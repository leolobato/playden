import Foundation
import Domain

extension LibraryModel {
    func transferLabel(for job: JobRecord) -> String? {
        guard job.id == activeInstallID, job.state == .running, job.stage == .download else { return nil }
        guard let rate = installTransfer else { return "Measuring speed…" }
        let formatter = ByteCountFormatter(); formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false
        let bytes = Int64(min(Double(Int64.max / 2), max(0, rate.bytesPerSecond.isFinite ? rate.bytesPerSecond : 0)))
        var text = formatter.string(fromByteCount: bytes) + "/s"
        if let seconds = rate.secondsRemaining, seconds.isFinite, seconds > 0 {
            let duration = Int(min(99 * 86400, ceil(seconds)))
            let estimate: String
            if duration >= 86400 { estimate = "More than a day left" }
            else if duration >= 3600 { estimate = "\(duration / 3600) h \(duration % 3600 / 60) min left" }
            else if duration >= 60 { estimate = "\(duration / 60) min \(duration % 60) s left" }
            else { estimate = "\(duration) s left" }
            text += " · " + estimate
        }
        return text
    }
    func downloadStats(for job: JobRecord) -> String {
        [job.bytesLabel, transferLabel(for: job)].compactMap { $0 }.joined(separator: " · ")
    }
}
