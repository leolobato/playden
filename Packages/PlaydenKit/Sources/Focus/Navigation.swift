public enum Direction: Sendable { case up, down, left, right }

/// Logical positions exist independently of the views mounted by a lazy grid.
public struct GridCursor: Equatable, Sendable {
    public private(set) var index: Int
    public private(set) var preferredColumn: Int
    public init(index: Int = 0, columns: Int = 6) {
        self.index = max(0, index)
        preferredColumn = max(0, index) % max(1, columns)
    }

    /// False means the caller should hand focus to a neighbouring container.
    @discardableResult
    public mutating func move(_ direction: Direction, count: Int, columns: Int) -> Bool {
        guard count > 0, columns > 0 else { return false }
        index = min(index, count - 1)
        let row = index / columns, column = index % columns
        switch direction {
        case .left:
            guard column > 0 else { return false }
            index -= 1; preferredColumn = index % columns
        case .right:
            guard column + 1 < columns, index + 1 < count else { return false }
            index += 1; preferredColumn = index % columns
        case .up:
            guard row > 0 else { return false }
            index = (row - 1) * columns + preferredColumn
        case .down:
            guard (row + 1) * columns < count else { return false }
            index = min((row + 1) * columns + preferredColumn, count - 1)
        }
        return true
    }

    public mutating func clamp(count: Int, columns: Int = 6) {
        index = min(index, max(0, count - 1))
        preferredColumn = index % max(1, columns)
    }
}

/// Timestamp-based repeat is deterministic in tests and independent of render frame rate.
public struct DirectionRepeater: Sendable {
    private var direction: Direction?
    private var began = 0.0
    private var last = 0.0
    public init() {}

    public mutating func update(_ value: Direction?, at time: Double) -> Direction? {
        guard let value else { direction = nil; return nil }
        if direction != value { direction = value; began = time; last = time; return value }
        let held = time - began
        guard held >= 0.4, time - last >= (held >= 1.5 ? 0.05 : 0.09) else { return nil }
        last = time
        return value
    }

    public static func direction(x: Float, y: Float, deadzone: Float = 0.25) -> Direction? {
        guard max(abs(x), abs(y)) >= deadzone else { return nil }
        return abs(x) > abs(y) ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down)
    }
}
