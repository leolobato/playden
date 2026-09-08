import Foundation

/// Core Graphics desktop coordinates, captured immediately before launch. The Windows helper
/// matches the full monitor rectangle after accounting for Wine's primary-display scale.
public struct GameDisplayTarget: Equatable, Sendable {
    public var bounds: CGRect
    public var primaryBounds: CGRect
    public init(bounds: CGRect, primaryBounds: CGRect) {
        self.bounds = bounds; self.primaryBounds = primaryBounds
    }
    func arguments() throws -> [String] {
        let values = [bounds.minX, bounds.minY, bounds.width, bounds.height, primaryBounds.width, primaryBounds.height]
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 131_072 }),
              values.dropFirst(2).allSatisfy({ $0 >= 1 }), primaryBounds.origin == .zero else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return values.map { String(Int($0.rounded())) }
    }
    func launchInput(executable: String, arguments: [String]) throws -> Data {
        try Self.launchInput(display: self, executable: executable, arguments: arguments)
    }
    static func launchInput(display: GameDisplayTarget?, executable: String, arguments: [String]) throws -> Data {
        var data = Data()
        func append(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        for value in try display?.arguments() ?? Array(repeating: "0", count: 6) { append(UInt32(bitPattern: Int32(value)!)) }
        let values = [executable] + arguments
        guard values.count <= 1024 else { throw CocoaError(.fileReadCorruptFile) }
        append(UInt32(values.count))
        for value in values {
            let units = Array(value.utf16)
            guard units.count < 32768, !units.contains(0) else { throw CocoaError(.fileReadCorruptFile) }
            append(UInt32(units.count))
            for unit in units { var little = unit.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        }
        guard data.count <= 256 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}
