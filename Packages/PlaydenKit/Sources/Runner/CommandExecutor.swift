import Foundation
import Darwin
import Domain

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool
    public let cancelled: Bool
    public init(exitCode: Int32, output: String, timedOut: Bool = false, cancelled: Bool = false) {
        self.exitCode = exitCode; self.output = output; self.timedOut = timedOut; self.cancelled = cancelled
    }
}
public protocol CommandExecuting: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}
/// Finite administrative commands only. Game supervision uses a separate lifetime and state model.
/// Each command owns a process group, so timeout/cancel also stops its descendants.
public struct CommandExecutor: CommandExecuting {
    public init() {}
    public func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let cancellation = CancellationFlag()
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await Task.detached(priority: .utility) {
                    try Self.execute(executable: executable, arguments: arguments, timeout: timeout, cancellation: cancellation)
                }.value
            } onCancel: { cancellation.cancel() }
            DiagnosticOutputContext.sink?(.init(tool: executable.lastPathComponent, exitCode: result.exitCode,
                timedOut: result.timedOut, cancelled: result.cancelled, output: result.output))
            return result
        } catch {
            DiagnosticOutputContext.sink?(.init(tool: executable.lastPathComponent, exitCode: nil,
                cancelled: error is CancellationError || Task.isCancelled,
                output: error is POSIXError ? error.localizedDescription : "The command could not start."))
            throw error
        }
    }
    private static func execute(executable: URL, arguments: [String], timeout: TimeInterval, cancellation: CancellationFlag) throws -> CommandResult {
        guard executable.isFileURL, !executable.path.utf8.contains(0), arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        defer { close(descriptors[0]); close(descriptors[1]) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        var emptySignals = sigset_t(), defaultSignals = sigset_t()
        sigemptyset(&emptySignals); sigemptyset(&defaultSignals)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaultSignals, signal) }
        posix_spawnattr_setsigmask(&attributes, &emptySignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("CX_") && !$0.key.hasPrefix("WINE")
        }.merging(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], uniquingKeysWith: { _, new in new })
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let error = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        let start = ContinuousClock.now
        var stopping: ContinuousClock.Instant?
        var status: Int32 = 0
        var output = DiagnosticOutputBuffer(), buffer = [UInt8](repeating: 0, count: 8192)
        var timedOut = false, cancelled = false
        func drain() {
            // Bound both memory and work per poll, even if a tool floods its output.
            for _ in 0..<16 {
                let count = read(descriptors[0], &buffer, buffer.count)
                guard count > 0 else { break }
                output.append(Data(buffer.prefix(count)))
            }
        }
        while true {
            drain()
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited == -1 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
            if stopping == nil {
                cancelled = cancellation.isCancelled
                timedOut = start.duration(to: .now) >= .seconds(max(0.01, timeout))
                if cancelled || timedOut { stopping = .now; kill(-pid, SIGTERM) }
            } else if stopping!.duration(to: .now) >= .seconds(2) { kill(-pid, SIGKILL) }
            // This synchronous loop runs on the detached utility task, never the UI actor.
            usleep(20_000)
        }
        if stopping != nil { kill(-pid, SIGKILL) }
        drain()
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return CommandResult(exitCode: exitCode, output: output.text, timedOut: timedOut, cancelled: cancelled)
    }
}
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}
