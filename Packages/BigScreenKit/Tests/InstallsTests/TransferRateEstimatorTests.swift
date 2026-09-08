import XCTest
import Domain
@testable import Installs

final class TransferRateEstimatorTests: XCTestCase {
    func testCompressedSpeedAndUncompressedETAExcludeCachedWork() throws {
        var meter = TransferRateEstimator(now: 100)
        meter.record(.init(bytesCompleted: 8000, bytesTotal: 10000, currentFile: "cached", downloadedBytes: 0, freshlyWrittenBytes: 0), now: 100)
        XCTAssertNil(meter.metrics(now: 100.5))
        meter.record(.init(bytesCompleted: 9000, bytesTotal: 10000, currentFile: "new", downloadedBytes: 400, freshlyWrittenBytes: 1000), now: 102)
        let value = try XCTUnwrap(meter.metrics(now: 102))
        XCTAssertEqual(value.bytesPerSecond, 200)
        XCTAssertEqual(value.secondsRemaining, 2)
        // Counter regressions / stale callback deliveries do not subtract transferred bytes.
        meter.record(.init(bytesCompleted: 8100, bytesTotal: 10000, currentFile: "old", downloadedBytes: 30, freshlyWrittenBytes: 100), now: 103)
        XCTAssertEqual((try XCTUnwrap(meter.metrics(now: 103))).bytesPerSecond, 400.0 / 3, accuracy: 0.001)
        let stalled = try XCTUnwrap(meter.metrics(now: 112))
        XCTAssertEqual(stalled.bytesPerSecond, 0); XCTAssertNil(stalled.secondsRemaining)
    }
    func testNewInvocationAndUnsupportedSourceHaveNoOldRate() {
        var meter = TransferRateEstimator(now: 0)
        meter.record(.init(bytesCompleted: 100, bytesTotal: 200, currentFile: "file"), now: 2)
        XCTAssertNil(meter.metrics(now: 2))
        meter.record(.init(bytesCompleted: 100, bytesTotal: 200, currentFile: "file", downloadedBytes: 100, freshlyWrittenBytes: 100), now: 2)
        XCTAssertNotNil(meter.metrics(now: 2))
        meter = TransferRateEstimator(now: 20)
        XCTAssertNil(meter.metrics(now: 22))
        meter.record(.init(bytesCompleted: 200, bytesTotal: 200, currentFile: "cached", downloadedBytes: 0, freshlyWrittenBytes: 0), now: 22)
        XCTAssertEqual(meter.metrics(now: 22)?.bytesPerSecond, 0)
        XCTAssertNil(meter.metrics(now: 22)?.secondsRemaining)
    }
}
