import Foundation

public enum InstallationFilter: String, CaseIterable, Codable, Sendable {
    case any = "Any", installed = "Installed", notInstalled = "Not installed"
}
public struct LibraryRefinements: Codable, Equatable, Sendable {
    public var installation: InstallationFilter = .any
    public var source: String?
    public var genre: String?
    public var controller: ControllerSupport?
    public var compatibility: Compatibility?
    public init() {}
    public var isActive: Bool { self != Self() }
    public func includes(_ game: Game) -> Bool {
        let installed = game.status == .installed || game.status == .driveDisconnected
        return (installation == .any || (installation == .installed ? installed : !installed))
            && (source == nil || source == game.id.source)
            && (genre == nil || game.genres.contains { $0.localizedCaseInsensitiveCompare(genre!) == .orderedSame })
            && (controller == nil || controller == game.controllerSupport)
            && (compatibility == nil || compatibility == game.compatibility)
    }
}
