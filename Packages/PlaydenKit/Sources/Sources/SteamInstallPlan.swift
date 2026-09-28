import Foundation
import CryptoKit
import Domain
import SteamCore

struct SteamInstallPayload: Codable, Equatable, Sendable {
    var version = 1
    let app: AppInfo
    let manifests: [DepotManifest]
    let ownedDLC: [UInt32]
    // Absent in older plans, which selected every eligible depot. New plans pin only
    // the eligible depots granted by the account's packages (including regional editions).
    var authorizedDepotIDs: [UInt32]? = nil
    // Absent in plans from before platform choice, which are Windows plans.
    var platform: GamePlatform? = nil
}

/// Steam `oslist` values name platforms "windows", "macos" and "linux"; empty means every platform.
enum SteamOS {
    static func matches(_ osList: String, _ platform: GamePlatform) -> Bool {
        let wanted = platform == .windows ? "windows" : "macos"
        return osList.isEmpty || osList.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
    }
}

enum SteamPlanBuilder {
    static func build(game: SourceGameRecord, app: AppInfo, manifests: [DepotManifest], ownedApps: Set<UInt32>, ownedDepots: Set<UInt32>? = nil,
                      recipeVersion: Int? = nil, platform: GamePlatform = .windows) throws -> InstallPlan {
        guard game.id.source == "steam", UInt32(game.id.value) == app.appID, ownedApps.contains(app.appID) else {
            throw failure("Resolve", "This account does not own the selected game.")
        }
        let expected = try selectedDepots(app, ownedApps: ownedApps, ownedDepots: ownedDepots, platform: platform)
        guard !manifests.isEmpty, Set(manifests.map(\.depotID)).count == manifests.count,
              Set(manifests.map(\.depotID)) == Set(expected.map(\.id)),
              manifests.allSatisfy({ manifest in expected.contains { $0.id == manifest.depotID && $0.manifestGID == manifest.gid } }) else {
            throw failure("Resolve", "The store returned an incomplete or mismatched install manifest.")
        }
        var paths: [String: DepotManifest.File] = [:]
        var installed: UInt64 = 0, downloaded: UInt64 = 0, largest: UInt64 = 0
        var normalized: [DepotManifest] = []
        for manifest in manifests {
            try ResumableDepotDownload.validateManifest(manifest)
            var files: [DepotManifest.File] = []
            for file in manifest.files {
                let path = try relativePath(file.path)
                let key = path.lowercased().precomposedStringWithCanonicalMapping
                if let prior = paths[key] {
                    guard prior == file else { throw failure("Resolve", "Two game depots contain conflicting files: \(path)") }
                    continue
                }
                paths[key] = file; files.append(file)
                guard !file.isDirectory && !file.isSymlink else { continue }
                installed = try sum(installed, file.size); largest = max(largest, file.size)
                for chunk in file.chunks { downloaded = try sum(downloaded, UInt64(chunk.compressedSize)) }
            }
            normalized.append(DepotManifest(depotID: manifest.depotID, gid: manifest.gid, files: files,
                totalSize: files.filter { !$0.isDirectory && !$0.isSymlink }.reduce(0) { $0 + $1.size }))
        }
        // Also catch collisions between a file in one depot and a child path in another.
        try ResumableDepotDownload.validateManifest(DepotManifest(depotID: 0, gid: 0, files: normalized.flatMap(\.files), totalSize: installed))
        let launches = try launchOptions(app, files: Array(paths.values), ownedApps: ownedApps, platform: platform)
        let launch = launches[0].spec
        let recipeVersion = recipeVersion ?? SteamRecipes.latestVersion(for: game.id)
        for step in try SteamRecipes.steps(for: game.id, version: recipeVersion) { _ = try SteamRecipes.inputs(step, files: normalized.flatMap(\.files)) }
        let required = try sum(sum(sum(installed, installed), largest), 256 * 1024 * 1024)
        guard required <= UInt64(Int64.max), downloaded <= UInt64(Int64.max) else { throw failure("Estimate", "The game size exceeds supported storage limits.") }
        let dlc = Set(app.dlcAppIDs + app.depots.compactMap(\.dlcAppID) + app.launches.compactMap(\.requiredDLC)).intersection(ownedApps).sorted()
        let payload = SteamInstallPayload(app: app, manifests: normalized, ownedDLC: dlc,
            authorizedDepotIDs: ownedDepots.map { _ in expected.map(\.id) }, platform: platform == .windows ? nil : platform)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return InstallPlan(game: game, manifestIDs: Dictionary(uniqueKeysWithValues: manifests.map { (String($0.depotID), String($0.gid)) }),
            estimate: InstallEstimate(downloadBytes: Int64(downloaded), installedBytes: Int64(installed), requiredBytes: Int64(required)),
            launchSpec: launch, sourcePayload: try encoder.encode(payload), recipeVersion: recipeVersion, launchOptions: launches,
            platform: platform == .windows ? nil : platform)
    }
    static func selectedDepots(_ app: AppInfo, ownedApps: Set<UInt32>, ownedDepots: Set<UInt32>? = nil, platform: GamePlatform = .windows) throws -> [DepotInfo] {
        let eligible = app.depots.filter { depot in
            SteamOS.matches(depot.osList, platform) && depot.isEnglishOrAll && !depot.isSharedInstall
                && (ownedDepots?.contains(depot.id) ?? true)
                && ((!depot.isDLC && depot.dlcAppID == nil) || depot.dlcAppID.map { ownedApps.contains($0) } == true)
        }
        guard !eligible.isEmpty else { throw failure("Resolve", "This game has no downloadable \(platform.title) content for English.") }
        // Like the Steam client, skip depots with nothing on the public branch (beta-only or empty
        // depots, as in DEMON'S TILT's Mac build); the game still needs at least one that has content.
        let selected = eligible.filter { $0.manifestGID != nil && $0.manifestGID != 0 }
        guard !selected.isEmpty, Set(selected.map(\.id)).count == selected.count else {
            throw failure("Resolve", "The game’s \(platform.title) content is not available on its public branch.")
        }
        return selected.sorted { $0.id < $1.id }
    }
    static func launchOptions(_ app: AppInfo, files: [DepotManifest.File], ownedApps: Set<UInt32>, platform: GamePlatform = .windows) throws -> [LaunchOption] {
        // Manifests above are resolved from the public branch. Developer/beta-only
        // launch entries can point to executables absent from that content.
        let eligible = app.launches.filter {
            SteamOS.matches($0.osList, platform) && ($0.betaKey == nil || $0.betaKey == "" || $0.betaKey == "public")
                && ($0.requiredDLC == nil || $0.requiredDLC == 0 || ownedApps.contains($0.requiredDLC!))
        }
        guard !eligible.isEmpty, Set(eligible.map(\.id)).count == eligible.count else {
            throw failure("Resolve", "The game has no valid \(platform.title) launch configuration.")
        }
        let sorted = eligible.sorted {
            if ($0.type.lowercased() == "default") != ($1.type.lowercased() == "default") { return $0.type.lowercased() == "default" }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
        return try sorted.map { launch in
            let spec = try platform == .macOS ? macLaunchSpec(launch, files: files) : launchSpec(launch, files: files)
            let description = launch.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = description.isEmpty ? spec.executableRelativePath : description
            return LaunchOption(id: launch.id, title: title, spec: spec)
        }
    }
    private static func launchSpec(_ launch: AppLaunch, files: [DepotManifest.File]) throws -> LaunchSpec {
        // EA titles such as Need for Speed Most Wanted launch through `steam2ea://`, which hands
        // off to the EA app instead of starting an executable from the game's content.
        if let scheme = launch.executable.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) {
            throw failure("Resolve", launch.executable[scheme].lowercased() == "steam2ea://"
                ? "This game launches through the EA app, which Playden doesn’t support yet."
                : "This game launches through another store’s launcher, which Playden doesn’t support yet.")
        }
        let path = try relativePath(launch.executable)
        guard path.lowercased().hasSuffix(".exe"), let file = files.first(where: {
            !$0.isDirectory && !$0.isSymlink && (try? relativePath($0.path).lowercased()) == path.lowercased()
        }) else { throw failure("Resolve", "The configured Windows executable is missing from the game’s content.") }
        var working = try relativePath(launch.workingDirectory, allowRoot: true)
        if working != "." {
            guard let child = files.compactMap({ try? relativePath($0.path) }).first(where: { $0.lowercased().hasPrefix(working.lowercased() + "/") }) else {
                throw failure("Resolve", "The configured working directory is missing from the game’s content.")
            }
            working = child.split(separator: "/").prefix(working.split(separator: "/").count).joined(separator: "/")
        }
        return LaunchSpec(executableRelativePath: try relativePath(file.path), workingDirectoryRelativePath: working,
                          arguments: try WindowsArguments.parse(launch.arguments))
    }
    /// A macOS launch entry names an app bundle, or an executable inside one. Playden launches the
    /// bundle through Launch Services, so the spec names the bundle.
    private static func macLaunchSpec(_ launch: AppLaunch, files: [DepotManifest.File]) throws -> LaunchSpec {
        let path = try relativePath(launch.executable)
        let parts = path.split(separator: "/")
        guard let appIndex = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            throw failure("Resolve", "The game’s Mac launch entry is not an app.")
        }
        let bundle = parts[...appIndex].joined(separator: "/")
        let info = (bundle + "/Contents/Info.plist").lowercased()
        guard files.contains(where: { !$0.isDirectory && (try? relativePath($0.path).lowercased()) == info }) else {
            throw failure("Resolve", "The configured Mac app is missing from the game’s content.")
        }
        return LaunchSpec(executableRelativePath: bundle, arguments: try POSIXArguments.parse(launch.arguments))
    }
    static func payload(_ plan: InstallPlan, for gameID: GameID) throws -> SteamInstallPayload {
        guard plan.game.id == gameID, plan.language == "english" else { throw failure("Resolve", "The saved install plan is for a different game or version.") }
        let value = try JSONDecoder().decode(SteamInstallPayload.self, from: plan.sourcePayload)
        guard value.version == 1, gameID.source == "steam", String(value.app.appID) == gameID.value else {
            throw failure("Resolve", "The saved install manifest is invalid.")
        }
        let rebuilt = try build(game: plan.game, app: value.app, manifests: value.manifests, ownedApps: Set(value.ownedDLC + [value.app.appID]),
            ownedDepots: value.authorizedDepotIDs.map(Set.init), recipeVersion: plan.recipeVersion, platform: value.platform ?? .windows)
        guard rebuilt.manifestIDs == plan.manifestIDs, rebuilt.estimate == plan.estimate, rebuilt.launchSpec == plan.launchSpec,
              plan.launchOptions == nil || rebuilt.launchOptions == plan.launchOptions,
              try JSONDecoder().decode(SteamInstallPayload.self, from: rebuilt.sourcePayload) == value else {
            throw failure("Resolve", "The saved install plan has inconsistent content or launch settings.")
        }
        return value
    }
    static func relativePath(_ raw: String, allowRoot: Bool = false) throws -> String {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.contains(":"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw failure("Resolve", "A configured game path leaves the installation folder.")
        }
        let parts = path.split(separator: "/").filter { $0 != "." }
        guard !parts.contains(".."), parts.first?.lowercased() != ".gn-download", allowRoot || !parts.isEmpty else {
            throw failure("Resolve", "A configured game path is invalid.")
        }
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
    private static func sum(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw failure("Estimate", "The store returned an invalid game size.") }; return result.partialValue
    }
    static func failure(_ stage: String, _ reason: String) -> OperationFailure { OperationFailure(stage: stage, reason: reason, output: reason) }
}

/// Shell-style words for Mac launch arguments: spaces separate, quotes group, backslash escapes.
/// No variable or glob expansion.
enum POSIXArguments {
    static func parse(_ raw: String) throws -> [String] {
        guard !raw.contains("\0"), raw.utf8.count <= 32767 else { throw SteamPlanBuilder.failure("Resolve", "The game’s launch arguments are invalid.") }
        var result: [String] = [], current = "", inWord = false
        var quote: Character?, escaped = false
        for char in raw {
            if escaped { current.append(char); escaped = false; inWord = true; continue }
            if char == "\\" && quote != "'" { escaped = true; inWord = true; continue }
            if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
                continue
            }
            if char == "\"" || char == "'" { quote = char; inWord = true; continue }
            if char == " " || char == "\t" || char == "\n" {
                if inWord { result.append(current); current = ""; inWord = false }
                continue
            }
            current.append(char); inWord = true
        }
        guard quote == nil, !escaped else { throw SteamPlanBuilder.failure("Resolve", "The game’s launch arguments are invalid.") }
        if inWord { result.append(current) }
        return result
    }
}

/// Microsoft CRT argument rules. These are literal argv values, with no shell/variable expansion.
enum WindowsArguments {
    static func parse(_ raw: String) throws -> [String] {
        guard !raw.contains("\0"), raw.utf8.count <= 32767 else { throw SteamPlanBuilder.failure("Resolve", "The game’s launch arguments are invalid.") }
        let chars = Array(raw); var index = 0, result: [String] = []
        while index < chars.count {
            while index < chars.count && (chars[index] == " " || chars[index] == "\t") { index += 1 }
            guard index < chars.count else { break }
            var argument = "", quoted = false
            while index < chars.count {
                if !quoted && (chars[index] == " " || chars[index] == "\t") { break }
                var slashes = 0
                while index < chars.count && chars[index] == "\\" { slashes += 1; index += 1 }
                if index < chars.count && chars[index] == "\"" {
                    argument += String(repeating: "\\", count: slashes / 2)
                    if slashes % 2 == 1 { argument.append("\""); index += 1 }
                    else if quoted && index + 1 < chars.count && chars[index + 1] == "\"" { argument.append("\""); index += 2 }
                    else { quoted.toggle(); index += 1 }
                } else {
                    argument += String(repeating: "\\", count: slashes)
                    if index < chars.count {
                        if !quoted && (chars[index] == " " || chars[index] == "\t") { break }
                        argument.append(chars[index]); index += 1
                    }
                }
            }
            result.append(argument)
        }
        return result
    }
}
