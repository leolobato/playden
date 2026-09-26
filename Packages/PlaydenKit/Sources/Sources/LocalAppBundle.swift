import Foundation

/// What Playden reads from a Mac app bundle. It never writes inside the bundle.
public struct LocalAppBundle: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let bundleIdentifier: String?
    public let executableName: String?
    public let category: String?
    public let engine: String?
    /// The app embeds the Steam API and may quit or ask for the Steam client when started directly.
    public let usesSteam: Bool

    public var looksLikeGame: Bool {
        if let category, category == "public.app-category.games" || (category.hasPrefix("public.app-category.") && category.hasSuffix("-games")) { return true }
        return engine != nil
    }

    public init?(url: URL) {
        let info = url.appendingPathComponent("Contents/Info.plist")
        guard url.pathExtension.lowercased() == "app",
              let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            (plist[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        self.url = url
        title = string("CFBundleDisplayName") ?? string("CFBundleName") ?? url.deletingPathExtension().lastPathComponent
        bundleIdentifier = string("CFBundleIdentifier")
        executableName = string("CFBundleExecutable")
        category = string("LSApplicationCategoryType")?.lowercased()
        engine = Self.engine(in: url)
        usesSteam = Self.containsSteamAPI(url)
    }

    /// Marker files that engines put in their Mac builds.
    static func engine(in bundle: URL) -> String? {
        let contents = bundle.appendingPathComponent("Contents")
        let manager = FileManager.default
        func exists(_ path: String) -> Bool { manager.fileExists(atPath: contents.appendingPathComponent(path).path) }
        if exists("Frameworks/UnityPlayer.dylib") || exists("Resources/Data/Managed") || exists("Resources/Data/globalgamemanagers") { return "Unity" }
        if exists("UE4") || exists("UE") { return "Unreal" }
        if exists("Resources/game.ios") { return "GameMaker" }
        let resources = (try? manager.contentsOfDirectory(atPath: contents.appendingPathComponent("Resources").path)) ?? []
        if resources.contains(where: { $0.lowercased().hasSuffix(".pck") }) { return "Godot" }
        return nil
    }

    static func containsSteamAPI(_ bundle: URL) -> Bool {
        guard let files = FileManager.default.enumerator(at: bundle.appendingPathComponent("Contents"), includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return false }
        for case let file as URL in files where file.lastPathComponent == "libsteam_api.dylib" { return true }
        return false
    }

    /// Apps directly in `folder`, and one level below it (`common/<Game>/<Game>.app`). Bundles nested
    /// inside another bundle are helpers, never games of their own.
    public static func apps(in folder: URL, depth: Int = 2) -> [URL] {
        let manager = FileManager.default
        var found: [URL] = []
        func visit(_ directory: URL, level: Int) {
            guard level <= depth, let children = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                                  options: [.skipsHiddenFiles]) else { return }
            for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                if child.pathExtension.lowercased() == "app" { found.append(child) }
                else { visit(child, level: level + 1) }
            }
        }
        visit(folder, level: 1)
        return found
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
