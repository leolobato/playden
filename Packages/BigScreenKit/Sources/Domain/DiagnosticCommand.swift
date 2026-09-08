import Foundation

public struct DiagnosticCommand: Sendable {
    public let tool: String
    public let timestamp: Date
    public let exitCode: Int32?
    public let timedOut: Bool
    public let cancelled: Bool
    public let output: String
    public init(tool: String, timestamp: Date = .now, exitCode: Int32?, timedOut: Bool = false, cancelled: Bool = false, output: String) {
        self.tool = DiagnosticRedactor.redact(tool); self.timestamp = timestamp; self.exitCode = exitCode
        self.timedOut = timedOut; self.cancelled = cancelled; self.output = DiagnosticRedactor.redact(output)
    }
    public var text: String {
        let result = exitCode.map { "exit \($0)" } ?? "not started"
        return "\(ISO8601DateFormatter().string(from: timestamp))  \(tool) · \(result)"
            + (timedOut ? " · timed out" : "") + (cancelled ? " · cancelled" : "")
            + "\n" + (output.isEmpty ? "[No output]" : output) + "\n"
    }
}

/// Inherited by structured work and child Tasks, not by unrelated concurrent operations. The
/// executor reports outside its detached process-polling task so the scope is preserved.
public enum DiagnosticOutputContext {
    @TaskLocal public static var sink: (@Sendable (DiagnosticCommand) -> Void)?
}
