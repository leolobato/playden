import XCTest
import Domain
import Installs
@testable import BigScreen

final class DownloadTransferTests: XCTestCase {
    @MainActor func testRateOnlyAppearsForTheActiveDownloadingInvocation() {
        let model = LibraryModel(preview: false)
        var job = JobRecord(gameID: .init(source: "fake", value: "test"))
        job.stage = .download; job.state = .running
        model.activeInstallID = job.id
        XCTAssertEqual(model.transferLabel(for: job), "Measuring speed…")
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
