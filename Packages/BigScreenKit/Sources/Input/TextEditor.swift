/// A character-indexed editor so cursor movement/deletion never splits emoji or composed accents.
public struct TextEditorState: Equatable, Sendable {
    public private(set) var text: String
    public private(set) var cursor: Int
    public init(_ text: String = "") { self.text = text; cursor = text.count }
    public var beforeCursor: String { String(text.prefix(cursor)) }
    public var afterCursor: String { String(text.dropFirst(cursor)) }
    public mutating func insert(_ value: String) {
        let prefix = beforeCursor + value
        text = prefix + afterCursor
        cursor = min(prefix.count, text.count)
    }
    public mutating func backspace() {
        guard cursor > 0 else { return }
        text = String(text.prefix(cursor - 1)) + afterCursor
        cursor -= 1
    }
    public mutating func moveCursor(by offset: Int) { cursor = min(max(0, cursor + offset), text.count) }
}
