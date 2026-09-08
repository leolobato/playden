import XCTest
import Domain
import Installs
@testable import BigScreen

final class DownloadTransferTests: XCTestCase {
    @MainActor func testFileVerificationReplacesDownloadLabelsAndProgress() {
        let model = LibraryModel(preview: false)
        var job = JobRecord(gameID: .init(source: "fake", value: "test"))
        job.stage = .download; job.state = .running; job.bytesCompleted = 1000; job.bytesTotal = 4000
        model.activeInstallID = job.id
        model.installTransfer = .init(bytesPerSecond: 100, secondsRemaining: 30,
            verification: .init(file: "Game/Data0.bdt", bytesChecked: 500, bytesTotal: 1000))
        XCTAssertEqual(model.downloadStatusTitle(for: job), "Verifying file")
        XCTAssertEqual(model.downloadProgress(for: job), 0.5)
        XCTAssertTrue(model.downloadBytesLabel(for: job).hasSuffix(" checked"))
        XCTAssertNil(model.transferSpeedLabel(for: job))
        XCTAssertNil(model.transferTimeLabel(for: job))
        XCTAssertEqual(model.fileVerification(for: job)?.file, "Game/Data0.bdt")
        var paused = job; paused.state = .paused
        XCTAssertNil(model.fileVerification(for: paused))
        model.installTransfer = nil
        XCTAssertEqual(model.downloadStatusTitle(for: job), "Downloading")
        XCTAssertEqual(model.downloadProgress(for: job), 0.25)
        XCTAssertEqual(model.downloadBytesLabel(for: job), job.bytesLabel)
    }
    @MainActor func testRateOnlyAppearsForTheActiveDownloadingInvocation() {
        let model = LibraryModel(preview: false)
        var job = JobRecord(gameID: .init(source: "fake", value: "test"))
        job.stage = .download; job.state = .running
        model.activeInstallID = job.id
        XCTAssertEqual(model.transferLabel(for: job), "Measuring…")
        model.installTransfer = .init(bytesPerSecond: 38_000_000, secondsRemaining: 134)
        XCTAssertEqual(model.transferLabel(for: job), "38 MB/s · About 3 min left")
        var paused = job; paused.state = .paused
        XCTAssertNil(model.transferLabel(for: paused))
        var verifying = job; verifying.stage = .validate
        XCTAssertNil(model.transferLabel(for: verifying))
        model.activeInstallID = UUID()
        XCTAssertNil(model.transferLabel(for: job))
        model.activeInstallID = job.id
        model.installTransfer = .init(bytesPerSecond: 0, secondsRemaining: nil)
        XCTAssertEqual(model.transferLabel(for: job), "0 bytes/s")
    }
}
