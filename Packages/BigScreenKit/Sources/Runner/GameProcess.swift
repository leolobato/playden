import Foundation
import Darwin
import Domain

public struct GameProcessPoll: Sendable {
    public let exitCode: Int32?
    public let output: String
    public let exited: Bool
    public init(exitCode: Int32?, output: String, exited: Bool? = nil) { self.exitCode = exitCode; self.output = output; self.exited = exited ?? (exitCode != nil) }
}
public protocol GameProcess: Sendable {
    var identity: ProcessIdentity { get }
    func poll() -> GameProcessPoll
    func signalGroup(_ signal: Int32)
}
public protocol GameProcessLaunching: Sendable {
    func start(executable: URL, arguments: [String], environment: [String: String]) throws -> any GameProcess
}
public struct GameProcessLauncher: GameProcessLaunching {
    public init() {}
    public func start(executable: URL, arguments: [String], environment: [String: String]) throws -> any GameProcess {
        try ChildProcess(executable: executable, arguments: arguments, environment: environment)
    }
}
/// Reattaches observation after launcher restart. A non-child's exit status is unknown, not zero.
struct RecoveredGameProcess: GameProcess {
    let identity: ProcessIdentity
    let output: String
    let inspector: any RuntimeInspecting
    func poll() -> GameProcessPoll {
        let current = inspector.identity(of: identity.pid)
        let missing = current.map { $0 != identity } ?? (kill(identity.pid, 0) != 0 && errno == ESRCH)
        return .init(exitCode: nil, output: output, exited: missing)
    }
    func signalGroup(_ signal: Int32) {
        guard RuntimeProcessInspector().identity(of: identity.pid) == identity else { return }
        kill(-identity.pid, signal)
    }
}
/// Owns the directly spawned child, including waitpid/reaping. Games have no arbitrary runtime
/// timeout. Output is bounded and drained without blocking the UI or retaining an unbounded log.
private final class ChildProcess: GameProcess, @unchecked Sendable {
    let identity: ProcessIdentity
    private let descriptor: Int32
    private let lock = NSLock()
    private var status: Int32?
    private var output = Data()
    init(executable: URL, arguments: [String], environment: [String: String]) throws {
        guard executable.isFileURL, !executable.path.utf8.contains(0), arguments.allSatisfy({ !$0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else { throw CocoaError(.fileReadInvalidFileName) }
        var pipes: [Int32] = [0, 0]
        guard pipe(&pipes) == 0 else { throw POSIXError(.EIO) }
        var keepReader = false
        defer { close(pipes[1]); if !keepReader { close(pipes[0]) } }
        _ = fcntl(pipes[0], F_SETFL, O_NONBLOCK)
        for fd in pipes { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&actions, pipes[0]); posix_spawn_file_actions_addclose(&actions, pipes[1])
        var empty = sigset_t(), defaults = sigset_t()
        sigemptyset(&empty); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigmask(&attributes, &empty); posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let inherited = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"].contains($0.key) }
        let values = inherited.merging(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], uniquingKeysWith: { _, new in new }).merging(environment, uniquingKeysWith: { _, new in new })
        let envp = values.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: Int32 = 0
        let result = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!) } }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        guard let identity = RuntimeProcessInspector().identity(of: pid) else {
            kill(-pid, SIGKILL); var status: Int32 = 0; _ = waitpid(pid, &status, 0)
            throw POSIXError(.ESRCH)
        }
        self.identity = identity; descriptor = pipes[0]; keepReader = true
    }
    deinit { close(descriptor) }
    func poll() -> GameProcessPoll {
        lock.withLock {
            var bytes = [UInt8](repeating: 0, count: 8192)
            for _ in 0..<32 {
                let size = read(descriptor, &bytes, bytes.count)
                if size <= 0 { break }
                output.append(contentsOf: bytes.prefix(size))
                if output.count > 256 * 1024 { output.removeFirst(output.count - 256 * 1024) }
            }
            if status == nil {
                var value: Int32 = 0
                if waitpid(identity.pid, &value, WNOHANG) == identity.pid { status = (value & 0x7f) == 0 ? ((value >> 8) & 0xff) : 128 + (value & 0x7f) }
            }
            return .init(exitCode: status, output: DiagnosticRedactor.redact(String(decoding: output, as: UTF8.self)))
        }
    }
    func signalGroup(_ signal: Int32) {
        lock.withLock {
            guard status == nil, RuntimeProcessInspector().identity(of: identity.pid) == identity else { return }
            kill(-identity.pid, signal)
        }
    }
}
