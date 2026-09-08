import Foundation

/// Finite source-preparation utilities run in the already owned game runtime. The source
/// supplies its bundled tool; the runtime verifies bottle ownership and bounds execution.
public protocol RuntimeToolRunning: Sendable {
    func runTool(executable: URL, arguments: [String], in bottle: GameBottle) async throws
}
