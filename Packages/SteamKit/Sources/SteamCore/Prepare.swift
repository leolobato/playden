import Foundation
import CryptoKit

// Swift lift of SteamUtils.ensureSteamSettings/replaceSteamApi/restoreSteamApi
// from Android baseline d8535825398afb1446d63f95ba53698cf1586847.
// SteamUtils.kt file commit: a449fdee330d8a35c1aaa3f1dcf664f0618269ca.

public struct GBEAssets: Sendable {
    public static let steamAPI32SHA256 = "4cc9dfcab8b4df0db507fa91d0acec6e58693fd4edd78dc80d39bda8072d08ed"
    public static let steamAPI64SHA256 = "513430ac8b869b0eed258d9e5feba5176a35446b3b61a63d01ab1d87683cdd1b"

    public let steamAPI32: URL
    public let steamAPI64: URL

    public init(steamAPI32: URL, steamAPI64: URL) {
        self.steamAPI32 = steamAPI32
        self.steamAPI64 = steamAPI64
    }

    public static func bundled() throws -> GBEAssets {
        guard let x86 = Bundle.module.url(forResource: "steam_api", withExtension: "dll",
                                          subdirectory: "steampipe"),
              let x64 = Bundle.module.url(forResource: "steam_api64", withExtension: "dll",
                                          subdirectory: "steampipe") else {
            throw SteamError.prepare("SteamCore is missing bundled gbe_fork DLLs")
        }
        let assets = GBEAssets(steamAPI32: x86, steamAPI64: x64)
        guard try sha256(x86) == steamAPI32SHA256, try sha256(x64) == steamAPI64SHA256 else {
            throw SteamError.prepare("bundled gbe_fork DLL hash mismatch")
        }
        return assets
    }

    func url(for architecture: PEArchitecture) -> URL {
        architecture == .x86_64 ? steamAPI64 : steamAPI32
    }
}

public struct PrepareAccount: Sendable {
    public let accountName: String
    public let steamID: UInt64
    public let language: String

    public init(accountName: String, steamID: UInt64, language: String = "english") {
        self.accountName = accountName
        self.steamID = steamID
        self.language = language.lowercased()
    }

    public var accountID: UInt32 { UInt32(truncatingIfNeeded: steamID) }
}

public struct PrepareIdentity: Sendable {
    public let account: PrepareAccount
    public let storedAuth: StoredAuth?

    public static func resolve(offline: Bool, language: String,
                               loadStoredAuth: () -> StoredAuth?) throws -> PrepareIdentity {
        if offline {
            return PrepareIdentity(
                account: PrepareAccount(accountName: "Playden", steamID: 0, language: language),
                storedAuth: nil)
        }
        guard let storedAuth = loadStoredAuth() else { throw SteamError.notLoggedIn }
        return PrepareIdentity(
            account: PrepareAccount(accountName: storedAuth.accountName,
                                    steamID: storedAuth.steamID, language: language),
            storedAuth: storedAuth)
    }
}

public struct PrepareMetadata: Sendable {
    public var installDir: String
    public var installedDepotIDs: [UInt32]?
    public var dlcAppIDs: [UInt32]
    public var forceDLC: Bool
    public var ufs: UFS
    public var encryptedAppTicket: Data?
    public var userStats: SteamUserStatsData?
    public var achievementSchema: Data?

    public init(installDir: String = "", installedDepotIDs: [UInt32]? = nil,
                dlcAppIDs: [UInt32] = [], forceDLC: Bool = false, ufs: UFS = UFS(),
                encryptedAppTicket: Data? = nil, userStats: SteamUserStatsData? = nil,
                achievementSchema: Data? = nil) {
        self.installDir = installDir
        self.installedDepotIDs = installedDepotIDs
        self.dlcAppIDs = dlcAppIDs
        self.forceDLC = forceDLC
        self.ufs = ufs
        self.encryptedAppTicket = encryptedAppTicket
        self.userStats = userStats
        self.achievementSchema = achievementSchema
    }
}

public struct PreparedDLL: Sendable {
    public let dll: URL
    public let backup: URL
    public let architecture: PEArchitecture
    public let interfaceCount: Int
}

public struct SteamStubRequirement: Sendable {
    public let executable: URL
    public let entryPointRVA: UInt32
}

public struct PrepareResult: Sendable {
    public let dlls: [PreparedDLL]
    public let steamStubRequirements: [SteamStubRequirement]
    public let ticketIncluded: Bool
    public let achievementCount: Int
}

public struct RestoreResult: Sendable {
    public let restoredDLLs: [URL]
}

public struct SteamPreparer {
    public let assets: GBEAssets
    public var maxDepth = 10

    public init(assets: GBEAssets) { self.assets = assets }

    public func prepare(appID: UInt32, gameDirectory: URL, account: PrepareAccount,
                        metadata: PrepareMetadata, offline: Bool = false) throws -> PrepareResult {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: gameDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SteamError.prepare("game directory does not exist: \(gameDirectory.path)")
        }
        let dllURLs = try files(in: gameDirectory) { name in
            name.caseInsensitiveCompare("steam_api.dll") == .orderedSame
                || name.caseInsensitiveCompare("steam_api64.dll") == .orderedSame
        }
        guard !dllURLs.isEmpty else {
            throw SteamError.prepare("no steam_api.dll or steam_api64.dll under \(gameDirectory.path)")
        }

        let asset32Inspection = try PEInspector.inspect(assets.steamAPI32)
        let asset64Inspection = try PEInspector.inspect(assets.steamAPI64)
        guard asset32Inspection.architecture == .x86, asset64Inspection.architecture == .x86_64 else {
            throw SteamError.prepare("bundled gbe_fork DLL architectures are invalid")
        }
        let bundledHashes = try Set([sha256(assets.steamAPI32), sha256(assets.steamAPI64)])

        try? fm.removeItem(at: gameDirectory.appendingPathComponent(".steam_dll_restored"))
        var prepared: [PreparedDLL] = []
        var backupPaths: [String] = []
        var achievementCount = 0

        for dll in dllURLs {
            let backup = URL(fileURLWithPath: dll.path + ".orig")
            let hasBackup = fm.fileExists(atPath: backup.path)
            let original = hasBackup ? backup : dll
            let currentHash = try sha256(dll)
            if !hasBackup && bundledHashes.contains(currentHash) {
                throw SteamError.prepare("\(dll.path) is already a gbe_fork DLL but has no .orig backup")
            }
            let inspection = try PEInspector.inspect(original)
            let expected: PEArchitecture = dll.lastPathComponent.caseInsensitiveCompare("steam_api64.dll") == .orderedSame
                ? .x86_64 : .x86
            guard inspection.architecture == expected else {
                throw SteamError.prepare("\(dll.lastPathComponent) is \(inspection.architecture.rawValue), expected \(expected.rawValue)")
            }

            let interfaceCount = try prepareInterfaces(from: original, beside: dll)
            if !hasBackup { try fm.copyItem(at: dll, to: backup) }
            try Data(contentsOf: assets.url(for: inspection.architecture)).write(to: dll, options: .atomic)
            try writeSettings(appID: appID, beside: dll, gameDirectory: gameDirectory,
                              account: account, metadata: metadata, offline: offline)
            if let schema = metadata.achievementSchema ?? metadata.userStats?.schema, !schema.isEmpty {
                let result = try StatsAchievementsGenerator.generate(
                    schema: schema, userStats: metadata.userStats,
                    configDirectory: dll.deletingLastPathComponent().appendingPathComponent("steam_settings"))
                achievementCount += result.achievements.count
            }
            backupPaths.append(relativePath(of: backup, under: gameDirectory))
            prepared.append(PreparedDLL(dll: dll, backup: backup, architecture: inspection.architecture,
                                        interfaceCount: interfaceCount))
        }

        let uniqueBackups = Array(Set(backupPaths)).sorted()
        try write(uniqueBackups.joined(separator: "\n") + "\n",
                  to: gameDirectory.appendingPathComponent("orig_dll_path.txt"))
        fm.createFile(atPath: gameDirectory.appendingPathComponent(".steam_dll_replaced").path,
                      contents: Data())

        return PrepareResult(dlls: prepared,
                             steamStubRequirements: classifySteamStubExecutables(in: gameDirectory),
                             ticketIncluded: metadata.encryptedAppTicket != nil,
                             achievementCount: achievementCount)
    }

    public func restore(gameDirectory: URL) throws -> RestoreResult {
        let fm = FileManager.default
        let pathsFile = gameDirectory.appendingPathComponent("orig_dll_path.txt")
        var backups: [URL] = []
        if let contents = try? String(contentsOf: pathsFile, encoding: .utf8) {
            backups = contents.split(whereSeparator: \.isNewline).map {
                gameDirectory.appendingPathComponent(String($0))
            }
        }
        if backups.isEmpty {
            backups = try files(in: gameDirectory) { name in
                name.caseInsensitiveCompare("steam_api.dll.orig") == .orderedSame
                    || name.caseInsensitiveCompare("steam_api64.dll.orig") == .orderedSame
            }
        }
        var restored: [URL] = []
        let root = gameDirectory.standardizedFileURL.path + "/"
        for backup in backups.sorted(by: { $0.path < $1.path }) {
            let standardized = backup.standardizedFileURL
            guard standardized.path.hasPrefix(root), standardized.lastPathComponent.lowercased().hasSuffix(".dll.orig"),
                  fm.fileExists(atPath: standardized.path) else { continue }
            let destination = URL(fileURLWithPath: String(standardized.path.dropLast(5)))
            try Data(contentsOf: standardized).write(to: destination, options: .atomic)
            restored.append(destination)
        }
        guard !restored.isEmpty else {
            throw SteamError.prepare("no original Steam API DLL backups found")
        }
        try? fm.removeItem(at: gameDirectory.appendingPathComponent(".steam_dll_replaced"))
        fm.createFile(atPath: gameDirectory.appendingPathComponent(".steam_dll_restored").path,
                      contents: Data())
        return RestoreResult(restoredDLLs: restored)
    }

    private func writeSettings(appID: UInt32, beside dll: URL, gameDirectory: URL,
                               account: PrepareAccount, metadata: PrepareMetadata,
                               offline: Bool) throws {
        let parent = dll.deletingLastPathComponent()
        let settings = parent.appendingPathComponent("steam_settings")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let appIDText = String(appID)
        let adjacentAppID = parent.appendingPathComponent("steam_appid.txt")
        let settingsAppID = settings.appendingPathComponent("steam_appid.txt")
        if !FileManager.default.fileExists(atPath: adjacentAppID.path) { try write(appIDText, to: adjacentAppID) }
        if !FileManager.default.fileExists(atPath: settingsAppID.path) { try write(appIDText, to: settingsAppID) }

        let depots = settings.appendingPathComponent("depots.txt")
        try? FileManager.default.removeItem(at: depots)
        if let installed = metadata.installedDepotIDs {
            try write(installed.sorted().map(String.init).joined(separator: "\n"), to: depots)
        }

        var userLines = [
            "[user::general]",
            "account_name=\(account.accountName)",
            "account_steamid=\(account.steamID)",
            "language=\(account.language)",
        ]
        if let ticket = metadata.encryptedAppTicket {
            userLines.append("ticket=\(ticket.base64EncodedString())")
        }
        userLines += [
            "",
            "[user::saves]",
            "local_save_path=C:\\Program Files (x86)\\Steam\\userdata\\\(account.accountID)",
        ]
        try SteamSettingsINI.write(userLines.joined(separator: "\n") + "\n",
                  to: settings.appendingPathComponent("configs.user.ini"),
                  removingKeys: metadata.encryptedAppTicket == nil ? ["user::general": ["ticket"]] : [:])

        var appLines = ["[app::dlcs]", "unlock_all=\(metadata.forceDLC ? 1 : 0)"]
        for dlc in Array(Set(metadata.dlcAppIDs)).sorted() { appLines.append("\(dlc)=dlc\(dlc)") }
        let installDir = metadata.installDir.isEmpty ? gameDirectory.lastPathComponent : metadata.installDir
        appLines += ["", "[app::paths]", "\(appID)=./steamapps/common/\(installDir)"]
        let cloud = cloudSaveLines(metadata.ufs)
        if !cloud.isEmpty { appLines += [""] + cloud }
        try SteamSettingsINI.write(appLines.joined(separator: "\n") + "\n",
                  to: settings.appendingPathComponent("configs.app.ini"),
                  replacingSections: ["app::dlcs", "app::cloud_save::win"])

        var mainLines = ["[main::connectivity]", "disable_lan_only=\(offline ? 0 : 1)"]
        if offline { mainLines.append("offline=1") }
        try SteamSettingsINI.write(mainLines.joined(separator: "\n") + "\n",
                  to: settings.appendingPathComponent("configs.main.ini"),
                  removingKeys: offline ? [:] : ["main::connectivity": ["offline"]])
        try write(Self.supportedLanguages.joined(separator: "\n"),
                  to: settings.appendingPathComponent("supported_languages.txt"))
    }

    private func cloudSaveLines(_ ufs: UFS) -> [String] {
        let patterns = ufs.saveFilePatterns.filter { $0.root.isWindows }
        guard !patterns.isEmpty else { return [] }
        var dirs: [String] = []
        for pattern in patterns {
            let root = pattern.root == .GameInstall ? "gameinstall" : pattern.root.rawValue
            let path = pattern.path
                .replacingOccurrences(of: "{64BitSteamID}", with: "{::64BitSteamID::}")
                .replacingOccurrences(of: "{Steam3AccountID}", with: "{::Steam3AccountID::}")
            let dir = "{::\(root)::}/\(path)"
            if !dirs.contains(dir) { dirs.append(dir) }
        }
        var lines = [
            "[app::cloud_save::general]",
            "create_default_dir=1",
            "create_specific_dirs=1",
            "",
            "[app::cloud_save::win]",
        ]
        for (index, dir) in dirs.enumerated() { lines.append("dir\(index + 1)=\(dir)") }
        return lines
    }

    private func classifySteamStubExecutables(in root: URL) -> [SteamStubRequirement] {
        guard let executables = try? files(in: root, matching: {
            $0.lowercased().hasSuffix(".exe") && !$0.lowercased().hasSuffix(".original.exe")
        }) else { return [] }
        return executables.compactMap { url in
            guard let inspection = try? PEInspector.inspect(url), inspection.requiresSteamStubRuntime else { return nil }
            return SteamStubRequirement(executable: url, entryPointRVA: inspection.entryPointRVA)
        }
    }

    private func files(in root: URL, matching predicate: (String) -> Bool) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let rootComponents = root.standardizedFileURL.pathComponents.count
        var result: [URL] = []
        for case let url as URL in enumerator {
            let depth = url.standardizedFileURL.pathComponents.count - rootComponents
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if depth > maxDepth {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true { continue }
            if values.isRegularFile == true, values.isSymbolicLink != true, predicate(url.lastPathComponent) {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func prepareInterfaces(from original: URL, beside dll: URL) throws -> Int {
        let directory = dll.deletingLastPathComponent()
        let settings = directory.appendingPathComponent("steam_settings")
        let canonical = settings.appendingPathComponent("steam_interfaces.txt")
        let legacy = directory.appendingPathComponent("steam_interfaces.txt")
        let generated = try extractInterfaces(from: original)
        guard !generated.isEmpty else {
            // Some DLLs have no discoverable versions. Retain manually supplied configuration.
            for file in [canonical, legacy] where FileManager.default.fileExists(atPath: file.path) {
                return try interfaceLines(in: file).count
            }
            return 0
        }
        // Regenerate from .orig on every prepare: older releases omitted underscore names.
        // Keep both locations in sync so a stale preferred file cannot shadow the repair.
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let contents = generated.joined(separator: "\n") + "\n"
        try write(contents, to: canonical)
        try write(contents, to: legacy)
        return generated.count
    }

    // Interface families accepted by gbe_fork's tools/generate_interfaces/generate_interfaces.cpp.
    private static let versionedInterfacePrefixes = [
        "STEAMAPPS_INTERFACE_VERSION", "SteamApps", "STEAMAPPLIST_INTERFACE_VERSION",
        "STEAMAPPTICKET_INTERFACE_VERSION", "SteamClient", "SteamController", "SteamFriends",
        "SteamGameServerStats", "SteamGameCoordinator", "SteamGameServer",
        "STEAMHTMLSURFACE_INTERFACE_VERSION_", "STEAMHTTP_INTERFACE_VERSION", "SteamInput",
        "STEAMINVENTORY_INTERFACE_V", "SteamMatchMakingServers", "SteamMatchMaking",
        "SteamMatchGameSearch", "SteamParties", "STEAMMUSIC_INTERFACE_VERSION",
        "STEAMMUSICREMOTE_INTERFACE_VERSION", "SteamNetworkingMessages", "SteamNetworkingSockets",
        "SteamNetworkingUtils", "SteamNetworking", "STEAMPARENTALSETTINGS_INTERFACE_VERSION",
        "STEAMREMOTEPLAY_INTERFACE_VERSION", "STEAMREMOTESTORAGE_INTERFACE_VERSION",
        "STEAMSCREENSHOTS_INTERFACE_VERSION", "STEAMTIMELINE_INTERFACE_V",
        "STEAMUGC_INTERFACE_VERSION", "SteamUser", "STEAMUSERSTATS_INTERFACE_VERSION",
        "SteamUtils", "STEAMVIDEO_INTERFACE_V", "STEAMUNIFIEDMESSAGES_INTERFACE_VERSION",
        "SteamMasterServerUpdater",
    ]

    private func extractInterfaces(from dll: URL) throws -> [String] {
        let bytes = try Data(contentsOf: dll, options: .mappedIfSafe)
        var current: [UInt8] = []
        var found = Set<String>()
        func flush(_ value: inout [UInt8], into found: inout Set<String>) {
            defer { value.removeAll(keepingCapacity: true) }
            guard value.count >= 10, let candidate = String(bytes: value, encoding: .ascii) else { return }
            let versioned = Self.versionedInterfacePrefixes.contains { prefix in
                guard candidate.hasPrefix(prefix) else { return false }
                let version = candidate.utf8.dropFirst(prefix.utf8.count)
                return !version.isEmpty && version.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
            }
            guard versioned || candidate == "STEAMCONTROLLER_INTERFACE_VERSION" else { return }
            found.insert(candidate)
        }
        for byte in bytes {
            if byte >= 0x20 && byte <= 0x7e { current.append(byte) }
            else { flush(&current, into: &found) }
        }
        flush(&current, into: &found)
        // New SDKs retain the legacy SteamClient() export at v017 alongside newer versions.
        if found.contains("SteamClient017") {
            found = found.filter { !$0.hasPrefix("SteamClient") || $0 == "SteamClient017" }
        }
        return found.sorted()
    }

    private func interfaceLines(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(rootPath.count))
    }

    private func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url, options: .atomic)
    }

    private static let supportedLanguages = [
        "arabic", "bulgarian", "schinese", "tchinese", "czech", "danish", "dutch", "english",
        "finnish", "french", "german", "greek", "hungarian", "italian", "japanese", "koreana",
        "norwegian", "polish", "portuguese", "brazilian", "romanian", "russian", "spanish",
        "latam", "swedish", "thai", "turkish", "ukrainian", "vietnamese",
    ]
}

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        .map { String(format: "%02x", $0) }.joined()
}
