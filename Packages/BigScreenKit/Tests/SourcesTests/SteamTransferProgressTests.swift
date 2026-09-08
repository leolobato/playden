import XCTest
import Domain
@testable import Sources

final class SteamTransferProgressTests: XCTestCase {
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
