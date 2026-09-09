import Foundation
import Darwin
import Domain

public protocol PrimaryDisplayHolding: Sendable {
    var target: GameDisplayTarget { get }
    func release() async
}

/// The pipe lifetime is independent of CrossOver. Closing it, or Playden exiting, ends
/// the native helper; macOS reverts that helper's application-scoped configuration.
public actor TemporaryPrimaryDisplay: PrimaryDisplayHolding {
    public nonisolated let target: GameDisplayTarget
    private let process: Process
    private let lifetime: FileHandle
    private let output: FileHandle
    private var cleanup: Task<Void, Never>?

    private init(target: GameDisplayTarget, process: Process, lifetime: FileHandle, output: FileHandle) {
        self.target = target; self.process = process; self.lifetime = lifetime; self.output = output
    }
    deinit {
        try? lifetime.close(); try? output.close()
        if process.isRunning { process.terminate() }
    }

    public static func acquire(target: GameDisplayTarget, helper: URL) async throws -> TemporaryPrimaryDisplay {
        guard let uuid = target.displayUUID, UUID(uuidString: uuid) != nil else {
            throw OperationFailure(stage: "Prepare game display", reason: PrimaryDisplayError.unavailable.localizedDescription, output: "Missing stable display UUID.")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = helper; process.arguments = ["--apply", uuid]
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        // Game processes must never inherit a writer that keeps the helper alive after Playden exits.
        for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        defer {
            try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        }
        do {
            try Task.checkCancellation()
            try process.run()
            try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
            let started = ContinuousClock.now
            var received = Data(), bytes = [UInt8](repeating: 0, count: 1024)
            while started.duration(to: .now) < .seconds(5) {
                try Task.checkCancellation()
                let count = read(descriptor, &bytes, bytes.count)
                if count > 0 { received.append(contentsOf: bytes.prefix(count)) }
                if let newline = received.firstIndex(of: 10) {
                    guard let screen = try? JSONDecoder().decode(PrimaryDisplayScreen.self, from: received.prefix(upTo: newline)),
                          screen.uuid.caseInsensitiveCompare(uuid) == .orderedSame, screen.isMain, screen.x == 0, screen.y == 0,
                          screen.width > 0, screen.height > 0 else { break }
                    try Task.checkCancellation()
                    guard process.isRunning else { break }
                    let bounds = CGRect(x: 0, y: 0, width: Int(screen.width), height: Int(screen.height))
                    return TemporaryPrimaryDisplay(target: .init(bounds: bounds, primaryBounds: bounds, displayUUID: screen.uuid,
                                                                 backingScaleFactor: target.backingScaleFactor),
                                                   process: process, lifetime: input.fileHandleForWriting, output: output.fileHandleForReading)
                }
                if received.count > 8192 || !process.isRunning || count == 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw OperationFailure(stage: "Prepare game display",
                reason: "The game monitor could not be made primary. Leave fullscreen apps and retry, or turn off Make game monitor primary.",
                output: String(decoding: received, as: UTF8.self))
        } catch {
            await stop(process, lifetime: input.fileHandleForWriting, output: output.fileHandleForReading).value
            throw error
        }
    }

    public func release() async {
        if cleanup == nil { cleanup = Self.stop(process, lifetime: lifetime, output: output) }
        await cleanup?.value
    }

    private static func stop(_ process: Process, lifetime: FileHandle, output: FileHandle) -> Task<Void, Never> {
        // Cleanup must run to completion even when the launch task was cancelled.
        Task.detached {
            try? lifetime.close()
            defer { try? output.close() }
            for _ in 0..<100 {
                if !process.isRunning { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning { process.terminate() }
            for _ in 0..<50 {
                if !process.isRunning { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}
