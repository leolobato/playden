import XCTest
@testable import SteamCore

/// Opt-in loopback HTTP evidence, separate from the plaintext install benchmark.
final class CDNTransportBenchmarkTests: XCTestCase {
    private struct Sample: Codable {
        let mode: String
        let repetition: Int
        let requests: Int
        let tcpConnections: Int
        let elapsedNanoseconds: UInt64
        let diagnostics: SteamPerformanceDiagnostics.Snapshot
    }

    func testHTTPConnectionReuseIfRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["PLAYDEN_STEAM_CDN_BENCHMARK_OUTPUT"] else {
            throw XCTSkip("set PLAYDEN_STEAM_CDN_BENCHMARK_OUTPUT for loopback HTTP measurements")
        }
        var samples: [Sample] = []
        // Alternate modes; each sample starts with a fresh local server and transport.
        for repetition in 1...3 {
            for reuse in [false, true] {
                let server = try KeepAliveHTTPFixture()
                defer { server.stop() }
                let diagnostics = SteamPerformanceDiagnostics()
                let pool = URLSessionCDNTransport()
                let started = DispatchTime.now().uptimeNanoseconds
                for request in 0..<64 {
                    let transport = reuse ? pool : URLSessionCDNTransport()
                    let data = try await CDNClient.get(server.url("/depot/\(request % 2)/chunk/fixture"),
                        diagnostics: diagnostics, transport: transport)
                    XCTAssertEqual(data, Data("fixture".utf8))
                }
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                let evidence = server.snapshot
                XCTAssertEqual(evidence.requests, 64)
                if reuse {
                    // Foundation owns pool size; accepted sockets can include a spare connection.
                    // Prove reuse without assuming that one session means exactly one TCP socket.
                    XCTAssertLessThan(evidence.connections, evidence.requests)
                } else { XCTAssertEqual(evidence.connections, 64) }
                XCTAssertEqual(diagnostics.snapshot()[.sessionCreation].count, reuse ? 1 : 64)
                XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].bytes, 448)
                samples.append(.init(mode: reuse ? "shared" : "per-request", repetition: repetition,
                    requests: evidence.requests, tcpConnections: evidence.connections,
                    elapsedNanoseconds: elapsed, diagnostics: diagnostics.snapshot()))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
