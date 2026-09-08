import Foundation

/// Maintains quoted credential context across process chunks and newlines. A discarded oversized
/// line still passes through this state, so its continuation cannot appear as ordinary output.
public struct DiagnosticLineRedactor: Sendable {
    private var quote: Character?
    private var escaped = false
    private static let expression = try! NSRegularExpression(pattern: #"(?i)[\"']?"# + DiagnosticRedactor.secretKey + #"[\"']?\s*[:=]\s*([\"'])"#)
    public init() {}
    public mutating func redact(_ fragment: String) -> String {
        var text = fragment
        var prefix = ""
        if let quote {
            guard let end = closingQuote(in: text, quote: quote, escaped: &escaped) else { return "[REDACTED]" }
            self.quote = nil; escaped = false
            text = String(text[end...]); prefix = "[REDACTED]"
        }
            for match in Self.expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text), let candidate = text[range].first else { continue }
                var escape = false
                if closingQuote(in: String(text[range.upperBound...]), quote: candidate, escaped: &escape) == nil {
                    quote = candidate; escaped = escape; break
                }
            }
        return prefix + DiagnosticRedactor.redact(text)
    }
    private func closingQuote(in text: String, quote: Character, escaped: inout Bool) -> String.Index? {
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == quote { return text.index(after: index) }
        }
        return nil
    }
}
