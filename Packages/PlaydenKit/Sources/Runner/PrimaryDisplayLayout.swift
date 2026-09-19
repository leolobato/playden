import Foundation
import CoreGraphics
import ColorSync

// Compiled into both Runner and the standalone helper. Planning is pure and never changes a display.
public struct PrimaryDisplayScreen: Codable, Equatable, Sendable {
    public let id: UInt32
    public let uuid: String
    public let x: Int32
    public let y: Int32
    public let width: Int32
    public let height: Int32
    public let isMain: Bool
    public let isMirrored: Bool

    public init(id: UInt32, uuid: String, x: Int32, y: Int32, width: Int32, height: Int32,
                isMain: Bool = false, isMirrored: Bool = false) {
        self.id = id; self.uuid = uuid; self.x = x; self.y = y
        self.width = width; self.height = height; self.isMain = isMain; self.isMirrored = isMirrored
    }
}

public struct PrimaryDisplayLayout: Codable, Equatable, Sendable {
    public let original: [PrimaryDisplayScreen]
    public let proposed: [PrimaryDisplayScreen]
    public let targetID: UInt32
    public var changesPrimary: Bool { original.first(where: { $0.isMain })?.id != targetID }

    public init(screens: [PrimaryDisplayScreen], targetUUID: String) throws {
        guard let target = screens.first(where: { $0.uuid.caseInsensitiveCompare(targetUUID) == .orderedSame }) else {
            throw PrimaryDisplayError.unavailable
        }
        guard !screens.isEmpty, screens.count <= 32, Set(screens.map(\.id)).count == screens.count,
              Set(screens.map { $0.uuid.lowercased() }).count == screens.count,
              screens.filter(\.isMain).count == 1,
              screens.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { throw PrimaryDisplayError.invalidLayout }
        guard !screens.contains(where: \.isMirrored) else { throw PrimaryDisplayError.mirrored }
        original = screens; targetID = target.id
        // Move all origins by the same amount so relative placement remains intact.
        proposed = try screens.map { screen in
            let x = Int64(screen.x) - Int64(target.x), y = Int64(screen.y) - Int64(target.y)
            guard abs(x) <= 131_072, abs(y) <= 131_072 else { throw PrimaryDisplayError.invalidLayout }
            return .init(id: screen.id, uuid: screen.uuid, x: Int32(x), y: Int32(y), width: screen.width,
                         height: screen.height, isMain: screen.id == target.id)
        }.sorted { ($0.id == target.id ? 0 : 1, $0.id) < ($1.id == target.id ? 0 : 1, $1.id) }
    }
}

public struct PrimaryDisplayHelperFailure: Codable, Sendable {
    public let error: String
    public init(error: String) { self.error = error }
}

public enum PrimaryDisplayError: Error, LocalizedError {
    case unavailable, invalidLayout, mirrored, configuration(Int32), didNotSwitch
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The game monitor is unavailable. Choose a connected monitor in Settings → Display."
        case .invalidLayout: "The Mac’s display arrangement could not be read."
        case .mirrored: "Temporary primary display is unavailable while displays are mirrored."
        case .configuration: "macOS could not change the main display. Leave fullscreen apps and retry, or turn off Make game monitor primary."
        case .didNotSwitch: "macOS did not make the game monitor primary. The game was not started."
        }
    }
}

public enum PrimaryDisplaySystem {
    public static func screens() throws -> [PrimaryDisplayScreen] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        let error = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        guard error == .success, count > 0, count < ids.count else { throw PrimaryDisplayError.invalidLayout }
        return try ids.prefix(Int(count)).map { id in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { throw PrimaryDisplayError.invalidLayout }
            let bounds = CGDisplayBounds(id)
            let values = [bounds.minX, bounds.minY, bounds.width, bounds.height]
            guard values.allSatisfy({ $0.isFinite && abs($0) <= 131_072 }) else { throw PrimaryDisplayError.invalidLayout }
            return .init(id: id, uuid: CFUUIDCreateString(nil, uuid) as String,
                         x: Int32(bounds.minX.rounded()), y: Int32(bounds.minY.rounded()),
                         width: Int32(bounds.width.rounded()), height: Int32(bounds.height.rounded()),
                         isMain: id == CGMainDisplayID(), isMirrored: CGDisplayIsInMirrorSet(id) != 0)
        }
    }

    /// Called only in the short-lived native helper, never in the Playden process.
    /// macOS owns rollback to the session configuration when that helper exits.
    public static func applyForHelperLifetime(_ layout: PrimaryDisplayLayout) throws {
        guard layout.changesPrimary else { return }
        // Refuse a stale plan; a connection or mode may have changed before this transaction.
        guard try screens().sorted(by: { $0.id < $1.id }) == layout.original.sorted(by: { $0.id < $1.id }) else {
            throw PrimaryDisplayError.invalidLayout
        }
        var configuration: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&configuration)
        guard error == .success, let configuration else { throw PrimaryDisplayError.configuration(error.rawValue) }
        for screen in layout.proposed {
            error = CGConfigureDisplayOrigin(configuration, screen.id, screen.x, screen.y)
            guard error == .success else {
                CGCancelDisplayConfiguration(configuration)
                throw PrimaryDisplayError.configuration(error.rawValue)
            }
        }
        error = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
        guard error == .success else { throw PrimaryDisplayError.configuration(error.rawValue) }
    }
}
