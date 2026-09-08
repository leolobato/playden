import Foundation

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
}
public enum RuntimeProcessKind: String, Codable, Sendable { case game, service, server, wrapper }
public struct RuntimeProcess: Codable, Equatable, Sendable {
    public let identity: ProcessIdentity
    public let kind: RuntimeProcessKind
    public let executable: String
    public init(identity: ProcessIdentity, kind: RuntimeProcessKind, executable: String) {
        self.identity = identity; self.kind = kind; self.executable = executable
    }
}
public struct GameWindow: Codable, Equatable, Sendable {
    public let id: UInt32
    public let process: ProcessIdentity
    public init(id: UInt32, process: ProcessIdentity) { self.id = id; self.process = process }
}
public struct RunningGame: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let bottle: GameBottle
    public let launcher: ProcessIdentity
    public let startedAt: Date
    public init(id: UUID = UUID(), bottle: GameBottle, launcher: ProcessIdentity, startedAt: Date = .now) {
        self.id = id; self.bottle = bottle; self.launcher = launcher; self.startedAt = startedAt
    }
}
public enum RunPhase: String, Codable, Sendable { case launching, running, stopping, exited }
public struct RunSnapshot: Codable, Equatable, Sendable {
    public var run: RunningGame
    public var phase: RunPhase
    public var processes: [RuntimeProcess]
    public var window: GameWindow?
    public var hadWindow: Bool
    public var exitCode: Int32?
    public var forced: Bool
    public var failure: OperationFailure?
    public var output: String
    public init(run: RunningGame, phase: RunPhase = .launching, processes: [RuntimeProcess] = [], window: GameWindow? = nil,
                hadWindow: Bool = false, exitCode: Int32? = nil, forced: Bool = false, failure: OperationFailure? = nil, output: String = "") {
        self.run = run; self.phase = phase; self.processes = processes; self.window = window; self.hadWindow = hadWindow
        self.exitCode = exitCode; self.forced = forced; self.failure = failure; self.output = DiagnosticRedactor.redact(output)
    }
}
public protocol GameRunner: Sendable {
    /// True while source staging needs validation, including an interrupted previous preparation.
    @discardableResult func prepare(_ bottle: GameBottle) async throws -> Bool
    /// Acknowledge only after source staging and its validated launch metadata are durably saved.
    func completePreparation(_ bottle: GameBottle) async throws
    func launch(_ spec: LaunchSpec, in bottle: GameBottle, directory: URL) async throws -> RunningGame
    func observe(_ run: RunningGame) async -> AsyncStream<RunSnapshot>
    func recover(_ snapshot: RunSnapshot) async throws -> RunSnapshot
    func terminate(_ run: RunningGame, force: Bool) async throws
}
public extension GameRunner {
    func completePreparation(_ bottle: GameBottle) async throws {}
}
