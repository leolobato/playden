import XCTest
import Domain
@testable import Sources

final class SteamTransferProgressTests: XCTestCase {
    func testVerificationKeepsTransferCountersAndClearsOnNextFile() throws {
        let samples = TransferSamples()
        let progress = SteamTransferProgress(total: 20_000, report: samples.append)
        progress.received(100)
        let previousSequence = try XCTUnwrap(samples.last?.sequence)
        let check = InstallFileVerification(file: "large", bytesChecked: 500, bytesTotal: 1000)
        progress.assembled(depot: 1, completed: 1000, fresh: 1000, file: "large", verification: check)
        XCTAssertEqual(samples.last?.verification, check)
        XCTAssertEqual(samples.last?.downloadedBytes, 100)
        XCTAssertEqual(samples.last?.freshlyWrittenBytes, 1000)
        XCTAssertGreaterThan(try XCTUnwrap(samples.last?.sequence), previousSequence)
        progress.assembled(depot: 1, completed: 1000, fresh: 1000, file: "next")
        XCTAssertNil(samples.last?.verification)
    }
    func testConcurrentResponsesAndMultipleDepotsKeepSeparateCounters() async throws {
        let samples = TransferSamples()
        let bridge = SteamTransferProgress(total: 20_000, report: samples.append)
        bridge.assembled(depot: 1, completed: 8000, fresh: 0, file: "cached")
        XCTAssertEqual(samples.last?.downloadedBytes, 0)
        XCTAssertEqual(samples.last?.freshlyWrittenBytes, 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { bridge.received(10) } }
        }
        bridge.assembled(depot: 1, completed: 9000, fresh: 1000, file: "first")
        bridge.assembled(depot: 2, completed: 10_000, fresh: 500, file: "second")
        bridge.assembled(depot: 1, completed: 8500, fresh: 500, file: "delayed")
        let value = try XCTUnwrap(samples.last)
        XCTAssertEqual(value.bytesCompleted, 10_000)
        XCTAssertEqual(value.downloadedBytes, 1000)
        XCTAssertEqual(value.freshlyWrittenBytes, 1500)
    }
}
private final class TransferSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [InstallProgress] = []
    func append(_ value: InstallProgress) { lock.lock(); defer { lock.unlock() }; samples.append(value) }
    var last: InstallProgress? { lock.lock(); defer { lock.unlock() }; return samples.last }
}
