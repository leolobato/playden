import Foundation
import Domain

/// Pure mappings from `RuntimeSettings` to the CrossOver mechanisms that carry them: process
/// environment (launch-only), bottle configuration (`cxbottle.conf`, persistent) and a registry
/// script imported through `reg.exe`. Kept side-effect free so each mapping is independently
/// unit-testable; `CrossOverRunner` owns the ordering and process supervision around them.
enum RuntimeMechanisms {
    /// Environment keys Playden manages on the game's behalf. A user-supplied value for any of
    /// these would silently collide with a mechanism above, so `effectiveSpec` rejects it instead.
    static let managedKeys: Set<String> = [
        "CX_GRAPHICS_BACKEND", "WINEMSYNC", "WINEESYNC", "DXVK_FRAME_RATE",
        "MTL_HUD_ENABLED", "DXVK_HUD", "WINE_LARGE_ADDRESS_AWARE"
    ]

    /// CrossOver's `cxbottle.conf` `[EnvironmentVariables]` section wins over the process
    /// environment, so the graphics backend and sync mode must be written there.
    static func bottleEnvironment(_ settings: RuntimeSettings) -> [String: String] {
        var environment = ["CX_GRAPHICS_BACKEND": settings.graphics.rawValue]
        switch settings.synchronization {
        case .msync: environment["WINEMSYNC"] = "1"; environment["WINEESYNC"] = "0"
        case .esync: environment["WINEMSYNC"] = "0"; environment["WINEESYNC"] = "1"
        case .off: environment["WINEMSYNC"] = "0"; environment["WINEESYNC"] = "0"
        }
        return environment
    }

    /// Values carried through the launched process's environment rather than the bottle
    /// configuration, since they only matter for this one run.
    static func launchEnvironment(_ settings: RuntimeSettings) -> [String: String] {
        var environment: [String: String] = [:]
        if settings.performanceOverlay {
            environment["MTL_HUD_ENABLED"] = "1"
            if settings.graphics == .dxvk { environment["DXVK_HUD"] = "fps" }
        }
        if settings.frameLimit != .off { environment["DXVK_FRAME_RATE"] = settings.frameLimit.rawValue }
        if settings.largeAddressAware { environment["WINE_LARGE_ADDRESS_AWARE"] = "1" }
        return environment
    }

    /// A UTF-16LE `.reg` script (imported via `reg.exe import`) for the settings that only take
    /// effect through the registry: controller HID mode, Retina scaling and the virtual desktop.
    static func registryScript(_ settings: RuntimeSettings) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        lines.append(#"[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus]"#)
        lines.append("\"DisableHidraw\"=dword:0000000" + (settings.controller == .xboxCompatible ? "1" : "0"))
        lines.append("")
        lines.append(#"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#)
        lines.append("\"RetinaMode\"=\"\(settings.highResolution ? "y" : "n")\"")
        lines.append("")
        lines.append(#"[HKEY_CURRENT_USER\Software\Wine\Explorer]"#)
        lines.append(settings.virtualDesktop == .off ? "\"Desktop\"=-" : "\"Desktop\"=\"Default\"")
        lines.append("")
        lines.append(#"[HKEY_CURRENT_USER\Software\Wine\Explorer\Desktops]"#)
        lines.append(settings.virtualDesktop == .off ? "\"Default\"=-" : "\"Default\"=\"\(settings.virtualDesktop.rawValue)\"")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    static func registryData(_ settings: RuntimeSettings) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in registryScript(settings).utf16 {
            var little = unit.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func winver(_ settings: RuntimeSettings) -> String { settings.windowsVersion.rawValue }

    /// Folds `settings` into `spec`: appended launch arguments/DLL overrides, plus an environment
    /// where the user's own values win over the spec's but Playden's managed values always win.
    static func effectiveSpec(_ spec: LaunchSpec, settings: RuntimeSettings) throws -> LaunchSpec {
        guard settings.environment.keys.allSatisfy({ !managedKeys.contains($0) }) else {
            throw OperationFailure(stage: "Launch game", reason: "An environment variable in Game settings is reserved by Playden. Remove it and retry.", output: "")
        }
        var result = spec
        result.arguments += settings.launchArguments
        for value in settings.dllOverrides where !result.dllOverrides.contains(value) { result.dllOverrides.append(value) }
        var environment = spec.environment
        for (key, value) in settings.environment { environment[key] = value }
        for key in managedKeys { environment.removeValue(forKey: key) }
        for (key, value) in launchEnvironment(settings) { environment[key] = value }
        result.environment = environment
        return result
    }

    /// Rewrites only the given keys inside `[EnvironmentVariables]`, preserving every other line
    /// verbatim. Mirrors `BottleFolders.configure`'s parsing so both stay compatible with the same
    /// `cxbottle.conf` shape. Writes atomically only when the text actually changed.
    static func rewriteBottleEnvironment(at conf: URL, values: [String: String]) throws -> Bool {
        guard (try? conf.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
            throw OperationFailure(stage: "Apply game settings", reason: "Game settings could not be applied. Retry the launch.", output: "")
        }
        let original = try Data(contentsOf: conf)
        let bom = Data([0xEF, 0xBB, 0xBF])
        let hasBOM = original.starts(with: bom)
        guard let text = String(data: hasBOM ? original.dropFirst(3) : original, encoding: .utf8) else {
            throw OperationFailure(stage: "Apply game settings", reason: "Game settings could not be applied. Retry the launch.", output: "")
        }
        var lines: [String] = [], inEnvironment = false, found = false
        func appendSettings() { for key in values.keys.sorted() { lines.append("\"\(key)\" = \"\(values[key]!)\"") } }
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if inEnvironment { appendSettings() }
                inEnvironment = trimmed == "[EnvironmentVariables]"
                if inEnvironment { found = true }
            }
            if inEnvironment, let equals = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if values[key] != nil { continue }
            }
            lines.append(raw)
        }
        if inEnvironment { appendSettings() }
        if !found { lines.append("[EnvironmentVariables]"); appendSettings() }
        let result = lines.joined(separator: "\n")
        guard result != text else { return false }
        var output = hasBOM ? bom : Data()
        output.append(contentsOf: result.utf8)
        try output.write(to: conf, options: .atomic)
        let file = try FileHandle(forWritingTo: conf); defer { try? file.close() }; try file.synchronize()
        return true
    }
}
