import Foundation

/// Opt-in numeric measurements. No paths, URLs, identifiers, keys or credentials are retained.
/// Durations sum operation time, including concurrent operations; they are not wall elapsed time.
public final class SteamPerformanceDiagnostics: @unchecked Sendable {
    public enum Metric: String, CaseIterable, Codable, Sendable {
        case networkTransfer, sessionCreation, adler32, sha1, sha256
        case contentRead, fileWrite, checkpoint, fileSync, directorySync, directoryWalk
        case progressCallback, keyPreparation, preparation, emulatorPreparation, fileValidation, finalValidation
    }
    public struct Measurement: Codable, Equatable, Sendable {
        public var count: UInt64 = 0
        public var bytes: UInt64 = 0
        public var nanoseconds: UInt64 = 0
    }
    public struct Snapshot: Codable, Sendable {
        public let measurements: [String: Measurement]
        public subscript(_ metric: Metric) -> Measurement { measurements[metric.rawValue] ?? Measurement() }
    }
    private let lock = NSLock()
    private var measurements: [Metric: Measurement] = [:]
    public init() {}

    public func record(_ metric: Metric, bytes: UInt64 = 0, nanoseconds: UInt64 = 0) {
        lock.withLock {
            var value = measurements[metric] ?? Measurement()
            value.count += 1; value.bytes += bytes; value.nanoseconds += nanoseconds
            measurements[metric] = value
        }
    }
    public func snapshot() -> Snapshot {
        lock.withLock { Snapshot(measurements: Dictionary(uniqueKeysWithValues: Metric.allCases.map {
            ($0.rawValue, measurements[$0] ?? Measurement())
        })) }
    }
    public func start() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    public func finish(_ metric: Metric, since start: UInt64?, bytes: UInt64 = 0) {
        guard let start else { return }
        record(metric, bytes: bytes, nanoseconds: DispatchTime.now().uptimeNanoseconds - start)
    }
}

public extension Optional where Wrapped == SteamPerformanceDiagnostics {
    /// Nil diagnostics bypass the clock and lock; work and error behavior stay identical.
    func measure<T>(_ metric: SteamPerformanceDiagnostics.Metric, bytes: UInt64 = 0, _ work: () throws -> T) rethrows -> T {
        guard let diagnostics = self else { return try work() }
        let start = diagnostics.start()
        defer { diagnostics.finish(metric, since: start, bytes: bytes) }
        return try work()
    }
    /// Counts bytes actually read, including a short read; errors still record elapsed read time.
    func readContent(_ work: () throws -> Data) rethrows -> Data {
        guard let diagnostics = self else { return try work() }
        let start = diagnostics.start()
        var count: UInt64 = 0
        defer { diagnostics.finish(.contentRead, since: start, bytes: count) }
        let data = try work(); count = UInt64(data.count); return data
    }
}
