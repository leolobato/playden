import XCTest
import Domain
@testable import Installs

final class InstallProgressRelayTests: XCTestCase {
    func testBlockedConsumerCoalescesBurstAndDrainsFinalOnCancellation() async throws {
        let consumer = BlockedProgressConsumer()
        let relay = InstallProgressRelay { await consumer.consume($0) }
        relay.submit(.init(bytesCompleted: 0, bytesTotal: 10_000, currentFile: "fixture", sequence: 1))
        for _ in 0..<1000 {
            if await consumer.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let started = await consumer.started
        XCTAssertTrue(started)
        for index in 1...10_000 {
            relay.submit(.init(bytesCompleted: Int64(index), bytesTotal: 10_000, currentFile: "fixture",
                verification: index < 5000 ? .init(file: "partial", bytesChecked: Int64(index), bytesTotal: 5000) : nil,
                sequence: UInt64(index + 1)))
        }
        // Delayed callbacks cannot replace the final snapshot.
        relay.submit(.init(bytesCompleted: 50, bytesTotal: 10_000, currentFile: "fixture", sequence: 50))
        let finish = Task { await relay.finish() }
        finish.cancel()
        let before = await consumer.values
        XCTAssertEqual(before.count, 1, "Actual actor consumer is awaited, even while blocked")
        await consumer.release()
        await finish.value
        let values = await consumer.values, peak = await consumer.peak
        XCTAssertLessThanOrEqual(values.count, 3, "Only a phase boundary and latest snapshot may remain pending")
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(values.last?.bytesCompleted, 10_000)
        XCTAssertEqual(values.last?.sequence, 10_001)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0.sequence! < $1.sequence! && $0.bytesCompleted <= $1.bytesCompleted })
        relay.submit(.init(bytesCompleted: 10_000, bytesTotal: 10_000, currentFile: "fixture", sequence: 10_002))
        await relay.finish()
        let final = await consumer.values
        XCTAssertEqual(final, values, "Finished relay rejects late producer callbacks")
    }
}
private actor BlockedProgressConsumer {
    var values: [InstallProgress] = []
    var active = 0, peak = 0
    var started: Bool { !values.isEmpty }
    private var continuation: CheckedContinuation<Void, Never>?
    func consume(_ value: InstallProgress) async {
        active += 1; peak = max(peak, active); values.append(value)
        if values.count == 1 { await withCheckedContinuation { continuation = $0 } }
        active -= 1
    }
    func release() { continuation?.resume(); continuation = nil }
}
