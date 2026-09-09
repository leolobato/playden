import Foundation

public enum RuntimeSettingID: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case graphics, synchronization, controller, windowsVersion, launchOption
    case highResolution, virtualDesktop, temporaryPrimaryDisplay, steamOverlay, performanceOverlay, frameLimit, largeAddressAware
    case launchArguments, environmentVariables, libraryOverrides
}

public enum RuntimeSettingValue: Equatable, Sendable, Codable {
    case scalar(String)
    case list([String])
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .scalar(value) }
        else { self = .list(try container.decode([String].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .scalar(let value): try container.encode(value)
        case .list(let values): try container.encode(values)
        }
    }
}

/// Decodes a single JSON value permissively so an entry whose value has a shape `RuntimeSettingValue`
/// doesn't recognize (e.g. a future setting's object or bool) can be dropped instead of failing the
/// whole map's decode.
struct LenientValue: Decodable {
    let value: RuntimeSettingValue?
    init(from decoder: Decoder) throws { value = try? RuntimeSettingValue(from: decoder) }
}

public enum RuntimeProfileSource: String, Codable, Sendable { case playdenDefault, profile, user, community }

public struct RuntimeProfile: Codable, Equatable, Sendable {
    public var base: String?
    public var overrides: [RuntimeSettingID: RuntimeSettingValue]
    public var source: RuntimeProfileSource
    public var appliedAt: Date?
    public init(base: String? = nil, overrides: [RuntimeSettingID: RuntimeSettingValue] = [:], source: RuntimeProfileSource = .playdenDefault, appliedAt: Date? = nil) {
        self.base = base; self.overrides = overrides; self.source = source; self.appliedAt = appliedAt
    }
    public var isCustom: Bool { !overrides.isEmpty }

    private enum CodingKeys: String, CodingKey { case base, overrides, source, appliedAt }
    /// Unknown override ids (from a future Playden version) are dropped rather than failing decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        base = try container.decodeIfPresent(String.self, forKey: .base)
        let rawOverrides = try container.decodeIfPresent([String: LenientValue].self, forKey: .overrides) ?? [:]
        overrides = Dictionary(uniqueKeysWithValues: rawOverrides.compactMap { key, wrapper -> (RuntimeSettingID, RuntimeSettingValue)? in
            guard let id = RuntimeSettingID(rawValue: key), let value = wrapper.value else { return nil }
            return (id, value)
        })
        source = try container.decodeIfPresent(RuntimeProfileSource.self, forKey: .source) ?? .playdenDefault
        appliedAt = try container.decodeIfPresent(Date.self, forKey: .appliedAt)
    }
}

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case d3dMetal = "d3dmetal", dxvk, dxmt
    public static let playdenDefault: GraphicsBackend = .d3dMetal
    public var title: String {
        switch self { case .d3dMetal: "Default (D3DMetal)"; case .dxvk: "DXVK"; case .dxmt: "DXMT" }
    }
}

public enum SynchronizationMode: String, Codable, CaseIterable, Sendable {
    case msync, esync, off
    public static let playdenDefault: SynchronizationMode = .msync
    public var title: String {
        switch self { case .msync: "Default (MSync)"; case .esync: "ESync"; case .off: "Off" }
    }
}

/// Raw values are the `cxstart --winver` tokens.
public enum WindowsVersion: String, Codable, CaseIterable, Sendable {
    case win10, win81, win7
    public static let playdenDefault: WindowsVersion = .win10
    public var title: String {
        switch self { case .win10: "Windows 10"; case .win81: "Windows 8.1"; case .win7: "Windows 7" }
    }
}

public enum VirtualDesktopSize: String, Codable, CaseIterable, Sendable {
    case off, hd1080 = "1920x1080", qhd1440 = "2560x1440", uhd2160 = "3840x2160"
    public static let playdenDefault: VirtualDesktopSize = .off
    public var title: String {
        switch self { case .off: "Off"; case .hd1080: "1920×1080"; case .qhd1440: "2560×1440"; case .uhd2160: "3840×2160" }
    }
}

public enum FrameLimit: String, Codable, CaseIterable, Sendable {
    case off, fps30 = "30", fps60 = "60", fps120 = "120"
    public static let playdenDefault: FrameLimit = .off
    public var title: String {
        switch self { case .off: "Off"; case .fps30: "30"; case .fps60: "60"; case .fps120: "120" }
    }
}

/// Scalar spelling for boolean settings; a single on/off vocabulary shared across the id space.
enum RuntimeToggle: String, Sendable {
    case on, off
    var boolValue: Bool { self == .on }
    init(_ value: Bool) { self = value ? .on : .off }
}

/// No environment-variable or registry names for CrossOver mechanisms belong here; Runner maps
/// resolved settings to those mechanisms. `sourceOptions` carries only Domain-level toggles such
/// as `"steam.overlay"`, and its keys must match `^[a-z][a-z0-9_.]{0,39}$`.
public struct RuntimeSettings: Equatable, Sendable {
    public var graphics: GraphicsBackend
    public var synchronization: SynchronizationMode
    public var controller: ControllerMode
    public var windowsVersion: WindowsVersion
    public var highResolution: Bool
    public var virtualDesktop: VirtualDesktopSize
    public var temporaryPrimaryDisplay: Bool
    public var performanceOverlay: Bool
    public var frameLimit: FrameLimit
    public var largeAddressAware: Bool
    public var launchOptionID: String?
    public var launchArguments: [String]
    public var environment: [String: String]
    public var dllOverrides: [String]
    public var sourceOptions: [String: String]
    public init(graphics: GraphicsBackend = .playdenDefault, synchronization: SynchronizationMode = .playdenDefault,
                controller: ControllerMode = .playdenDefault, windowsVersion: WindowsVersion = .playdenDefault,
                highResolution: Bool = true, virtualDesktop: VirtualDesktopSize = .playdenDefault, temporaryPrimaryDisplay: Bool = false,
                performanceOverlay: Bool = false, frameLimit: FrameLimit = .playdenDefault, largeAddressAware: Bool = false,
                launchOptionID: String? = nil, launchArguments: [String] = [], environment: [String: String] = [:],
                dllOverrides: [String] = [], sourceOptions: [String: String] = ["steam.overlay": "0"]) {
        self.graphics = graphics; self.synchronization = synchronization; self.controller = controller
        self.windowsVersion = windowsVersion; self.highResolution = highResolution; self.virtualDesktop = virtualDesktop
        self.temporaryPrimaryDisplay = temporaryPrimaryDisplay
        self.performanceOverlay = performanceOverlay; self.frameLimit = frameLimit; self.largeAddressAware = largeAddressAware
        self.launchOptionID = launchOptionID; self.launchArguments = launchArguments; self.environment = environment
        self.dllOverrides = dllOverrides; self.sourceOptions = sourceOptions
    }
    public static let playdenDefault = RuntimeSettings()
}
