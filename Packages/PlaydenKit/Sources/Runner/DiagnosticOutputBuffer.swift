import Foundation
import Domain

/// Retain recent complete lines only after redaction. Raw partial lines are bounded separately;
/// oversized lines are omitted while the pipe and credential context continue to be consumed.
struct DiagnosticOutputBuffer {
    private var history = Data(), pending = Data()
    private var redactor = DiagnosticLineRedactor()
    private var oversizedLine = false, truncated = false
    private let limit = 256 * 1024 - 128
    mutating func append(_ bytes: Data) {
        var remainder = bytes[...]
        while !remainder.isEmpty {
            let newline = remainder.firstIndex(of: 10)
            let end = newline.map { remainder.index(after: $0) } ?? remainder.endIndex
            let fragment = remainder[..<end]
            if oversizedLine {
                _ = redactor.redact(String(decoding: fragment, as: UTF8.self))
            } else if pending.count + fragment.count > limit {
                _ = redactor.redact(String(decoding: pending, as: UTF8.self))
                _ = redactor.redact(String(decoding: fragment, as: UTF8.self))
                pending.removeAll(keepingCapacity: false); oversizedLine = true; truncated = true
            } else { pending.append(contentsOf: fragment) }
            if newline != nil {
                if oversizedLine { history.append(Data("[Oversized output line omitted]\n".utf8)) }
                else { history.append(Data((redactor.redact(String(decoding: pending, as: UTF8.self)).trimmingCharacters(in: .newlines) + "\n").utf8)) }
                pending.removeAll(keepingCapacity: false); oversizedLine = false
                trimHistory()
            }
            remainder = remainder[end...]
        }
    }
    private mutating func trimHistory() {
        guard history.count > limit else { return }
        let excess = history.count - limit
        let tail = history.dropFirst(excess)
        if let newline = tail.firstIndex(of: 10) { history = Data(tail.suffix(from: tail.index(after: newline))) }
        else { history.removeAll(keepingCapacity: false) }
        truncated = true
    }
    var text: String {
        var view = self
        if !oversizedLine, !pending.isEmpty {
            view.history.append(Data(view.redactor.redact(String(decoding: pending, as: UTF8.self)).utf8))
        }
        view.trimHistory()
        return (view.truncated ? "[Process output truncated; earlier or oversized lines omitted.]\n" : "")
            + String(decoding: view.history, as: UTF8.self)
    }
}
