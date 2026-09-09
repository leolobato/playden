import Foundation

public struct CuratedProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let tryWhen: String
    public let shortHint: String
    public let settings: [RuntimeSettingID: RuntimeSettingValue]
    public let fallbackHint: String?
    public init(id: String, name: String, tryWhen: String, shortHint: String, settings: [RuntimeSettingID: RuntimeSettingValue], fallbackHint: String? = nil) {
        self.id = id; self.name = name; self.tryWhen = tryWhen; self.shortHint = shortHint
        self.settings = settings; self.fallbackHint = fallbackHint
    }

    private enum CodingKeys: String, CodingKey { case id, name, tryWhen, shortHint, settings, fallbackHint }
    /// Unknown setting ids (from a curated profile newer than this build) are dropped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tryWhen = try container.decode(String.self, forKey: .tryWhen)
        shortHint = try container.decode(String.self, forKey: .shortHint)
        let rawSettings = try container.decodeIfPresent([String: LenientValue].self, forKey: .settings) ?? [:]
        settings = Dictionary(uniqueKeysWithValues: rawSettings.compactMap { key, wrapper -> (RuntimeSettingID, RuntimeSettingValue)? in
            guard let id = RuntimeSettingID(rawValue: key), let value = wrapper.value else { return nil }
            return (id, value)
        })
        fallbackHint = try container.decodeIfPresent(String.self, forKey: .fallbackHint)
    }
}

public struct CuratedProfileCatalog: Equatable, Sendable {
    public let profiles: [CuratedProfile]
    public init(profiles: [CuratedProfile]) { self.profiles = profiles }
    public subscript(id: String) -> CuratedProfile? { profiles.first { $0.id == id } }
    public static let playdenDefaultID = "playden-default"

    private struct File: Decodable { let version: Int; let profiles: [CuratedProfile] }
    public static func decode(_ data: Data) throws -> CuratedProfileCatalog {
        CuratedProfileCatalog(profiles: try JSONDecoder().decode(File.self, from: data).profiles)
    }

    private static let cached: CuratedProfileCatalog = {
        guard let url = Bundle.module.url(forResource: "profiles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data) else { return CuratedProfileCatalog(profiles: []) }
        return catalog
    }()
    public static func bundled() -> CuratedProfileCatalog { cached }
}

public enum RuntimeResolver {
    public static func settings(_ profile: RuntimeProfile, catalog: CuratedProfileCatalog) -> RuntimeSettings {
        settings(from: values(profile, catalog: catalog).resolved)
    }

    /// Resolved map and base-profile map for the UI: resolved = defaults ⊕ base profile ⊕ overrides; base = defaults ⊕ base profile.
    public static func values(_ profile: RuntimeProfile, catalog: CuratedProfileCatalog) -> (resolved: [RuntimeSettingID: RuntimeSettingValue], base: [RuntimeSettingID: RuntimeSettingValue]) {
        var base = defaultValues
        if let id = profile.base, let curated = catalog[id] { for (key, value) in curated.settings { base[key] = value } }
        var resolved = base
        for (key, value) in profile.overrides { resolved[key] = value }
        return (resolved, base)
    }

    public static let defaultValues: [RuntimeSettingID: RuntimeSettingValue] = [
        .graphics: .scalar(GraphicsBackend.playdenDefault.rawValue),
        .synchronization: .scalar(SynchronizationMode.playdenDefault.rawValue),
        .controller: .scalar(ControllerMode.playdenDefault.rawValue),
        .windowsVersion: .scalar(WindowsVersion.playdenDefault.rawValue),
        .highResolution: .scalar(RuntimeToggle(true).rawValue),
        .virtualDesktop: .scalar(VirtualDesktopSize.playdenDefault.rawValue),
        .steamOverlay: .scalar(RuntimeToggle(false).rawValue),
        .performanceOverlay: .scalar(RuntimeToggle(false).rawValue),
        .frameLimit: .scalar(FrameLimit.playdenDefault.rawValue),
        .largeAddressAware: .scalar(RuntimeToggle(false).rawValue),
        .launchArguments: .list([]),
        .environmentVariables: .list([]),
        .libraryOverrides: .list([]),
    ]

    public static func normalized(_ profile: RuntimeProfile, catalog: CuratedProfileCatalog) -> RuntimeProfile {
        let base = values(profile, catalog: catalog).base
        var normalized = profile
        normalized.overrides = profile.overrides.filter { key, value in base[key] != value }
        return normalized
    }

    public static func displayName(_ profile: RuntimeProfile, catalog: CuratedProfileCatalog) -> String {
        let name = catalog[profile.base ?? CuratedProfileCatalog.playdenDefaultID]?.name ?? "Playden default"
        return profile.isCustom ? "Custom · from \(name)" : name
    }

    /// Invalid scalars fall back to the Playden default for that setting rather than failing.
    public static func settings(from values: [RuntimeSettingID: RuntimeSettingValue]) -> RuntimeSettings {
        func scalar(_ id: RuntimeSettingID) -> String? {
            if case .scalar(let value) = values[id] { return value }
            return nil
        }
        func list(_ id: RuntimeSettingID) -> [String] {
            if case .list(let value) = values[id] { return value }
            return []
        }
        var settings = RuntimeSettings.playdenDefault
        if let raw = scalar(.graphics), let value = GraphicsBackend(rawValue: raw) { settings.graphics = value }
        if let raw = scalar(.synchronization), let value = SynchronizationMode(rawValue: raw) { settings.synchronization = value }
        if let raw = scalar(.controller), let value = ControllerMode(rawValue: raw) { settings.controller = value }
        if let raw = scalar(.windowsVersion), let value = WindowsVersion(rawValue: raw) { settings.windowsVersion = value }
        if let raw = scalar(.highResolution), let value = RuntimeToggle(rawValue: raw) { settings.highResolution = value.boolValue }
        if let raw = scalar(.virtualDesktop), let value = VirtualDesktopSize(rawValue: raw) { settings.virtualDesktop = value }
        if let raw = scalar(.performanceOverlay), let value = RuntimeToggle(rawValue: raw) { settings.performanceOverlay = value.boolValue }
        if let raw = scalar(.frameLimit), let value = FrameLimit(rawValue: raw) { settings.frameLimit = value }
        if let raw = scalar(.largeAddressAware), let value = RuntimeToggle(rawValue: raw) { settings.largeAddressAware = value.boolValue }
        settings.launchOptionID = scalar(.launchOption)
        settings.launchArguments = list(.launchArguments)
        settings.dllOverrides = list(.libraryOverrides)
        var environment: [String: String] = [:]
        for entry in list(.environmentVariables) {
            guard let separator = entry.firstIndex(of: "="), separator > entry.startIndex else { continue }
            environment[String(entry[entry.startIndex..<separator])] = String(entry[entry.index(after: separator)...])
        }
        settings.environment = environment
        let steamOverlayOn = scalar(.steamOverlay).flatMap(RuntimeToggle.init(rawValue:))?.boolValue ?? false
        settings.sourceOptions["steam.overlay"] = steamOverlayOn ? "1" : "0"
        return settings
    }
}
