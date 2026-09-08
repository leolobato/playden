import Foundation

/// Finite source-preparation utilities run in the already owned game runtime. The source
/// supplies its bundled tool; the runtime verifies bottle ownership and bounds execution.
public protocol RuntimeToolRunning: Sendable {
    func runTool(executable: URL, arguments: [String], in bottle: GameBottle) async throws
    func preparePrerequisite(_ prerequisite: RuntimePrerequisite, executable: URL, in bottle: GameBottle) async throws
    func prerequisiteReady(_ prerequisite: RuntimePrerequisite, in bottle: GameBottle) async throws -> Bool
}
public struct RuntimePrerequisite: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let arguments: [String]
    /// Source-verified recipe, command and input-file identity, independent of temporary paths.
    public let fingerprint: Data
    public init(id: String, title: String, arguments: [String], fingerprint: Data) {
        self.id = id; self.title = title; self.arguments = arguments; self.fingerprint = fingerprint
    }
}
public extension RuntimeToolRunning {
    func prerequisiteReady(_ prerequisite: RuntimePrerequisite, in bottle: GameBottle) async throws -> Bool { false }
    func preparePrerequisite(_ prerequisite: RuntimePrerequisite, executable: URL, in bottle: GameBottle) async throws {
        try await runTool(executable: executable, arguments: prerequisite.arguments, in: bottle)
    }
}
