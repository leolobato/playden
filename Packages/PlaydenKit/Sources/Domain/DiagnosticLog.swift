import Foundation

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var message: String
    public init(timestamp: Date, message: String) {
        self.timestamp = timestamp; self.message = DiagnosticRedactor.redact(message)
    }
}

/// Bounded, redacted diagnostics. Ownership tokens, credentials, launch environments and source
/// payloads are deliberately absent. Operational records remain independent of log rotation.
public struct DiagnosticLog: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let gameID: GameID
    public let kind: String
    public let startedAt: Date
    public var updatedAt: Date
    public var events: [DiagnosticEvent] = []
    public var omittedEvents = 0
    public var output = ""
    public var outputTruncated = false
    public var commandOutput: String?
    public var commandOutputTruncated: Bool?
    public init(id: UUID, gameID: GameID, kind: String, startedAt: Date) {
        self.id = id; self.gameID = gameID; self.kind = kind; self.startedAt = startedAt; self.updatedAt = startedAt
    }
    public mutating func record(_ message: String, at date: Date) {
        let redacted = DiagnosticRedactor.redact(message)
        let message = redacted.utf8.count > 8192 ? String(decoding: redacted.utf8.prefix(8192), as: UTF8.self) + " [truncated]" : redacted
        guard events.last?.message != message else { return }
        events.append(.init(timestamp: date, message: message)); updatedAt = max(updatedAt, date)
        if events.count > 512 { omittedEvents += events.count - 512; events.removeFirst(events.count - 512) }
    }
    public mutating func capture(_ text: String, at date: Date) {
        // Redact before truncation so a cut cannot turn a complete secret field into a leak.
        let redacted = DiagnosticRedactor.redact(text)
        let bytes = Array(redacted.utf8)
        let truncated = bytes.count > 256 * 1024
        let tail = bytes.suffix(256 * 1024).drop(while: { $0 & 0xC0 == 0x80 })
        let next = String(decoding: tail, as: UTF8.self)
        guard next != output || truncated != outputTruncated else { return }
        output = next; outputTruncated = truncated; updatedAt = max(updatedAt, date)
    }
    public mutating func captureCommand(_ command: DiagnosticCommand) {
        let bytes = Array(DiagnosticRedactor.redact((commandOutput ?? "") + command.text).utf8)
        commandOutputTruncated = commandOutputTruncated == true || bytes.count > 256 * 1024
        commandOutput = String(decoding: bytes.suffix(256 * 1024).drop(while: { $0 & 0xC0 == 0x80 }), as: UTF8.self)
        updatedAt = max(updatedAt, command.timestamp)
    }
    public var text: String {
        let formatter = ISO8601DateFormatter()
        var lines = ["Playden · \(kind)", "Operation: \(id.uuidString)", "Started: \(formatter.string(from: startedAt))", "", "Stage history"]
        if omittedEvents > 0 { lines.append("[\(omittedEvents) earlier events omitted]") }
        lines += events.map { "\(formatter.string(from: $0.timestamp))  \($0.message)" }
        if let commandOutput {
            lines += ["", "Setup and runtime commands (stdout / stderr)"]
            if commandOutputTruncated == true { lines.append("[Earlier command output omitted; showing the last 256 KiB]") }
            lines.append(commandOutput)
        }
        lines += ["", "Tool output (stdout / stderr)"]
        if outputTruncated { lines.append("[Earlier output omitted; showing the last 256 KiB]") }
        lines.append(output.isEmpty ? "No tool output captured." : output)
        return lines.joined(separator: "\n") + "\n"
    }
}
