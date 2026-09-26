import Foundation

public enum InstallationFilter: String, CaseIterable, Codable, Sendable {
    case any = "Any", installed = "Installed", notInstalled = "Not installed", missing = "Missing"
}
public struct LibraryRefinements: Codable, Equatable, Sendable {
    public var installation: InstallationFilter = .any
    public var source: String?
    public var genre: String?
    public var controller: ControllerSupport?
    public var compatibility: Compatibility?
    public var platform: GamePlatform?
    public init() {}
    public var isActive: Bool { self != Self() }
    public func includes(_ game: Game) -> Bool {
        let installed = [.installed, .driveDisconnected, .missing].contains(game.status)
        let installation = switch self.installation {
        case .any: true
        case .installed: installed
        case .notInstalled: !installed
        case .missing: game.status == .missing
        }
        let platform = self.platform.map { wanted in game.installedPlatform.map { $0 == wanted } ?? game.platforms.contains(wanted) } ?? true
        return installation && platform
            && (source == nil || source == game.id.source)
            && (genre == nil || game.genres.contains { $0.localizedCaseInsensitiveCompare(genre!) == .orderedSame })
            && (controller == nil || controller == game.controllerSupport)
            && (compatibility == nil || compatibility == game.compatibility)
    }
}
