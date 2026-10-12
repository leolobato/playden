import XCTest
import CryptoKit
import Domain
import SteamCore
@testable import Sources

/// Explicit opt-in; creates and removes only its own UUID fixture directories.
final class SteamInstallationBenchmarkTests: XCTestCase {
    func testInstallationFixtures() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PLAYDEN_STEAM_BENCHMARK_ROOT"] else {
            throw XCTSkip("Run scripts/benchmark-steam-install.sh with a fixture volume")
        }
        let parent = URL(fileURLWithPath: path, isDirectory: true)
        guard try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            XCTFail("Benchmark root must be an existing directory"); return
        }
        let iterations = Int(environment["PLAYDEN_STEAM_BENCHMARK_ITERATIONS"] ?? "3") ?? 3
        guard (1...10).contains(iterations) else { XCTFail("Use 1...10 repetitions"); return }
        var results: [BenchmarkResult] = []
        for iteration in 1...iterations {
            for fixture in ["large-file", "many-small-files"] {
                let directory = parent.appendingPathComponent(".playden-install-benchmark-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: directory) }
                let diagnostics = SteamPerformanceDiagnostics()
                let bytes = Data(repeating: 0x5a, count: fixture == "large-file" ? 1024 * 1024 : 16 * 1024)
                let pe = Self.executable()
                let hash = Data(Insecure.SHA1.hash(data: bytes)), checksum = Self.adler(bytes)
                let executableHash = Data(Insecure.SHA1.hash(data: pe))
                func file(_ path: String, _ data: Data) -> DepotManifest.File {
                    let hash = Data(Insecure.SHA1.hash(data: data))
                    return .init(path: path, size: UInt64(data.count), chunks: [.init(sha: hash, offset: 0,
                        compressedSize: UInt32(data.count), uncompressedSize: UInt32(data.count), checksum: Self.adler(data))], contentSHA1: hash)
                }
                var files = [file("Game.exe", pe), file("bin/steam_api64.dll", pe)]
                if fixture == "large-file" {
                    let chunks = (0..<128).map { index in
                        DepotManifest.Chunk(sha: hash, offset: UInt64(index * bytes.count), compressedSize: UInt32(bytes.count),
                            uncompressedSize: UInt32(bytes.count), checksum: checksum)
                    }
                    var wholeHash = Insecure.SHA1()
                    for _ in chunks { wholeHash.update(data: bytes) }
                    files.append(.init(path: "data/archive.bin", size: 128 * 1024 * 1024, chunks: chunks,
                        contentSHA1: Data(wholeHash.finalize())))
                } else {
                    for index in 0..<512 {
                        files.append(.init(path: "data/group\(index / 32)/file\(index).bin", size: UInt64(bytes.count),
                            chunks: [.init(sha: hash, offset: 0, compressedSize: UInt32(bytes.count),
                                uncompressedSize: UInt32(bytes.count), checksum: checksum)], contentSHA1: hash))
                    }
                }
                // Two depot engines share one collector, matching the live backend's per-depot lifetime.
                let manifests = [DepotManifest(depotID: 101, gid: 1, files: Array(files.prefix(2)), totalSize: 2048),
                    DepotManifest(depotID: 102, gid: 1, files: Array(files.dropFirst(2)), totalSize: files.dropFirst(2).reduce(0) { $0 + $1.size })]
                let app = AppInfo(appID: 100, name: "Fixture", depots: [.init(id: 101, manifestGID: 1), .init(id: 102, manifestGID: 1)],
                    launches: [.init(id: "0", executable: "Game.exe")])
                let fetch = SimulatedFixtureFetch(chunks: [hash: bytes, executableHash: pe])
                let backend = PerformanceFixtureBackend(content: .init(app: app, manifests: manifests,
                    entitlements: .init(appIDs: [100], depotIDs: [101, 102])), diagnostics: diagnostics, fetch: fetch)
                let game = SourceGameRecord(id: .init(source: "steam", value: "100"), title: "Fixture")
                let installer = SteamInstaller(game: game, backend: backend, diagnostics: diagnostics)
                let plan = try await installer.resolve()
                let start = DispatchTime.now().uptimeNanoseconds
                try await installer.download(plan, to: directory) { _ in }
                let downloaded = DispatchTime.now().uptimeNanoseconds
                let downloadMetrics = diagnostics.snapshot()
                let originals = try await installer.verifyOriginals(plan, at: directory, staging: nil)
                XCTAssertTrue(originals.isValid)
                let verified = DispatchTime.now().uptimeNanoseconds
                let originalMetrics = diagnostics.snapshot()
                let staging = try await installer.postInstall(plan, at: directory)
                let prepared = DispatchTime.now().uptimeNanoseconds
                let preparationMetrics = diagnostics.snapshot()
                _ = try await installer.validate(plan, at: directory, staging: staging)
                let validated = DispatchTime.now().uptimeNanoseconds
                let metrics = diagnostics.snapshot()
                XCTAssertEqual(metrics[.networkTransfer].count, 0)
                XCTAssertEqual(metrics[.sessionCreation].count, 0)
                XCTAssertEqual(metrics[.preparation].count, 1)
                XCTAssertEqual(metrics[.finalValidation].count, 1)
                let result = BenchmarkResult(fixture: fixture, iteration: iteration,
                    installedBytes: manifests.reduce(0) { $0 + $1.totalSize }, fileCount: files.count,
                    chunkConcurrency: 8, simulatedLatencyNanoseconds: 2_000_000, simulatedFetch: fetch.snapshot(),
                    downloadWallNanoseconds: downloaded - start, originalVerificationWallNanoseconds: verified - downloaded,
                    preparationWallNanoseconds: prepared - verified,
                    validationWallNanoseconds: validated - prepared, download: Self.delta(downloadMetrics),
                    originalVerification: Self.delta(originalMetrics, since: downloadMetrics),
                    preparation: Self.delta(preparationMetrics, since: originalMetrics),
                    validation: Self.delta(metrics, since: preparationMetrics))
                results.append(result)
                print("STEAM_BENCHMARK \(fixture) iteration=\(iteration) download_ms=\((downloaded - start) / 1_000_000) originals_ms=\((verified - downloaded) / 1_000_000) preparation_ms=\((prepared - verified) / 1_000_000) validation_ms=\((validated - prepared) / 1_000_000)")
            }
        }
        if let output = environment["PLAYDEN_STEAM_BENCHMARK_OUTPUT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
    private static func delta(_ current: SteamPerformanceDiagnostics.Snapshot,
                              since previous: SteamPerformanceDiagnostics.Snapshot? = nil) -> [String: SteamPerformanceDiagnostics.Measurement] {
        current.measurements.reduce(into: [:]) { result, entry in
            var value = entry.value
            if let old = previous?.measurements[entry.key] {
                value.count -= old.count; value.bytes -= old.bytes; value.nanoseconds -= old.nanoseconds
            }
            result[entry.key] = value
        }
    }
    private static func adler(_ data: Data) -> UInt32 {
        var a: UInt32 = 0, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return (b << 16) | a
    }
    private static func executable() -> Data {
        var data = Data(repeating: 0, count: 1024)
        func put(_ value: UInt32, _ offset: Int, _ count: Int = 4) {
            for i in 0..<count { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        data[0] = 0x4d; data[1] = 0x5a; put(0x80, 0x3c); data[0x80] = 0x50; data[0x81] = 0x45
        put(0x8664, 0x84, 2); put(1, 0x86, 2); put(0xf0, 0x94, 2); put(0x20b, 0x98, 2); put(0x1000, 0xa8)
        for (i, byte) in ".text".utf8.enumerated() { data[0x188 + i] = byte }
        put(0x1000, 0x190); put(0x1000, 0x194); put(0x200, 0x198)
        return data
    }
}

private struct BenchmarkResult: Encodable {
    let fixture: String
    let iteration: Int
    let installedBytes: UInt64
    let fileCount: Int
    let chunkConcurrency: Int
    let simulatedLatencyNanoseconds: UInt64
    let simulatedFetch: SimulatedFixtureFetch.Measurement
    let downloadWallNanoseconds: UInt64
    let originalVerificationWallNanoseconds: UInt64
    let preparationWallNanoseconds: UInt64
    let validationWallNanoseconds: UInt64
    let download: [String: SteamPerformanceDiagnostics.Measurement]
    let originalVerification: [String: SteamPerformanceDiagnostics.Measurement]
    let preparation: [String: SteamPerformanceDiagnostics.Measurement]
    let validation: [String: SteamPerformanceDiagnostics.Measurement]
}
private final class SimulatedFixtureFetch: @unchecked Sendable {
    struct Measurement: Encodable { var count: UInt64 = 0; var bytes: UInt64 = 0; var nanoseconds: UInt64 = 0 }
    let chunks: [Data: Data]
    private let lock = NSLock()
    private var measurement = Measurement()
    init(chunks: [Data: Data]) { self.chunks = chunks }
    func fetch(_ chunk: DepotManifest.Chunk, diagnostics: SteamPerformanceDiagnostics?) async throws -> Data {
        let start = DispatchTime.now().uptimeNanoseconds
        try await Task.sleep(nanoseconds: 2_000_000)
        guard let data = chunks[chunk.sha] else { throw SourceFailure.unavailable }
        lock.withLock {
            measurement.count += 1; measurement.bytes += UInt64(data.count)
            measurement.nanoseconds += DispatchTime.now().uptimeNanoseconds - start
        }
        // Mirror CDNClient.fetchChunk's validation of its decrypted response.
        try chunk.validate(data, diagnostics: diagnostics)
        return data
    }
    func snapshot() -> Measurement { lock.withLock { measurement } }
}
private struct PerformanceFixtureBackend: SteamInstallBackend {
    let content: ResolvedSteamContent
    let diagnostics: SteamPerformanceDiagnostics
    let fetch: SimulatedFixtureFetch
    func resolve(appID: UInt32, platform: GamePlatform) async throws -> ResolvedSteamContent { content }
    func download(_ payload: SteamInstallPayload, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        for manifest in payload.manifests {
            var download = ResumableDepotDownload(destination: directory, diagnostics: diagnostics)
            download.onProgress = { update in
                Optional(diagnostics).measure(.progressCallback) { progress(.init(bytesCompleted: Int64(update.bytesDone),
                    bytesTotal: Int64(update.bytesTotal), currentFile: update.file)) }
            }
            try await download.download(manifest: manifest) { chunk in try await fetch.fetch(chunk, diagnostics: diagnostics) }
        }
    }
}
