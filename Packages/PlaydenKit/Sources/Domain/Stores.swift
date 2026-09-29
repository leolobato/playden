import Foundation

/// Stable source identifiers. The UI and orchestration branch on capabilities, never on these.
public enum SourceID {
    public static let steam = "steam"
    public static let local = "local"
    public static let epic = "epic"
    public static let gog = "gog"
}

/// What a game runs as, independent of the store it comes from.
public enum GamePlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case windows, macOS
    public var title: String { self == .windows ? "Windows" : "macOS" }
}

public struct SourceCapabilities: Equatable, Sendable {
    /// `steam`: QR or password with Steam Guard. `deviceCode`: a code on the TV, approved on the phone.
    /// `webLogin`: the store's own login page, whose final address carries a code (PRD 10 AR-MULTI-10).
    public enum Account: Equatable, Sendable { case none, steam, deviceCode, webLogin }
    /// `download`: Playden installs owned files. `external`: games are already on disk and never owned.
    public enum Acquisition: Equatable, Sendable { case download, external }
    public var account: Account
    public var acquisition: Acquisition
    public var cloudSaves: Bool
    public init(account: Account, acquisition: Acquisition, cloudSaves: Bool = false) {
        self.account = account; self.acquisition = acquisition; self.cloudSaves = cloudSaves
    }
}

/// Legacy installations carry no binding and run in CrossOver.
public enum RuntimeBinding: String, Codable, Sendable {
    case crossOver, native
    public var platform: GamePlatform { self == .crossOver ? .windows : .macOS }
}

/// An app Playden found on disk. Its files belong to the user; Playden never writes or removes them.
public struct ExternalLocation: Codable, Equatable, Sendable {
    public enum Availability: String, Codable, Sendable { case available, volumeUnavailable, missing }
    public var bookmark: Data?
    public var lastKnownPath: URL
    public var bundleIdentifier: String?
    public var executableName: String?
    /// As of the last scan; Play checks again before launching.
    public var availability: Availability?
    /// The app embeds the Steam API and may need the Steam client.
    public var usesSteam: Bool?
    public init(bookmark: Data?, lastKnownPath: URL, bundleIdentifier: String? = nil, executableName: String? = nil,
                availability: Availability? = nil, usesSteam: Bool? = nil) {
        self.bookmark = bookmark; self.lastKnownPath = lastKnownPath
        self.bundleIdentifier = bundleIdentifier; self.executableName = executableName
        self.availability = availability; self.usesSteam = usesSteam
    }
}

/// A native app run. The bundle bounds process discovery the way a bottle prefix does for CrossOver.
public struct NativeRun: Codable, Equatable, Sendable {
    public let bundleURL: URL
    public let bundleIdentifier: String?
    public init(bundleURL: URL, bundleIdentifier: String?) { self.bundleURL = bundleURL; self.bundleIdentifier = bundleIdentifier }
}

public enum ExternalLocationFailure: Error, Equatable, Sendable {
    /// The volume that held the app is not mounted.
    case volumeUnavailable
    /// The app is gone from its location and its bookmark cannot find it.
    case missing
}

public struct SourceRegistry: Sendable {
    public let all: [any GameSource]
    public init(_ sources: [any GameSource]) {
        var seen = Set<String>()
        all = sources.filter { seen.insert($0.id).inserted }
    }
    public subscript(id: String) -> (any GameSource)? { all.first { $0.id == id } }
    public func displayName(for id: String) -> String { self[id]?.displayName ?? id.capitalized }
    /// Sources the player signs in to, in registry order.
    public var accountSources: [any GameSource] { all.filter { $0.capabilities.account != .none } }
}
