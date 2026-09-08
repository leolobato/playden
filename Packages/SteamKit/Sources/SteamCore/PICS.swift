import Foundation
import SteamProto

/// A depot as described by PICS appinfo, with the fields depot selection needs.
public struct DepotInfo: Codable, Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let osList: String        // "windows", "macos,linux", "" = all
    public let osArch: String
    public let language: String      // "" = all languages
    public let isSharedInstall: Bool // redistributable owned by another app
    public let isDLC: Bool           // gated behind a dlcappid
    public let dlcAppID: UInt32?
    public let manifestGID: UInt64?  // public branch manifest (nil = not downloadable for us)
    public let size: UInt64          // uncompressed bytes (from public branch entry)
    public let downloadSize: UInt64

    public init(id: UInt32, name: String = "", osList: String = "", osArch: String = "", language: String = "",
                isSharedInstall: Bool = false, isDLC: Bool = false, dlcAppID: UInt32? = nil,
                manifestGID: UInt64? = nil, size: UInt64 = 0, downloadSize: UInt64 = 0) {
        self.id = id; self.name = name; self.osList = osList; self.osArch = osArch; self.language = language
        self.isSharedInstall = isSharedInstall; self.isDLC = isDLC; self.dlcAppID = dlcAppID
        self.manifestGID = manifestGID; self.size = size; self.downloadSize = downloadSize
    }
    public var isWindows: Bool { osList.isEmpty || osList.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "windows" } }
    public var isEnglishOrAll: Bool { language.isEmpty || language.lowercased() == "english" }
}

public enum PathType: String, Codable, Sendable {
    case GameInstall, SteamUserData, WinMyDocuments, WinAppDataLocal
    case WinAppDataLocalLow, WinAppDataRoaming, WinSavedGames, WinProgramData
    case LinuxHome, LinuxXdgDataHome, LinuxXdgConfigHome, MacHome, MacAppSupport
    case None, Root

    public var isWindows: Bool {
        switch self {
        case .GameInstall, .SteamUserData, .WinMyDocuments, .WinAppDataLocal,
             .WinAppDataLocalLow, .WinAppDataRoaming, .WinSavedGames,
             .WinProgramData, .Root:
            return true
        default: return false
        }
    }

    static func from(_ value: String?) -> PathType {
        let key = value?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "%"))
        switch key {
        case "gameinstall": return .GameInstall
        case "steamuserdata", "steamuserbasestorage": return .SteamUserData
        case "winmydocuments", "steamclouddocuments": return .WinMyDocuments
        case "winappdatalocal": return .WinAppDataLocal
        case "winappdatalocallow": return .WinAppDataLocalLow
        case "winappdataroaming": return .WinAppDataRoaming
        case "winsavedgames": return .WinSavedGames
        case "winprogramdata": return .WinProgramData
        case "linuxhome": return .LinuxHome
        case "linuxxdgdatahome": return .LinuxXdgDataHome
        case "linuxxdgconfighome": return .LinuxXdgConfigHome
        case "machome": return .MacHome
        case "macappsupport": return .MacAppSupport
        case "root", "windowshome", "root_mod": return .Root
        default: return .None
        }
    }
}

public struct SaveFilePattern: Codable, Equatable, Sendable {
    public let root: PathType
    public let path: String
    public let pattern: String
    public let recursive: Int
    public let uploadRoot: PathType
    public let uploadPath: String

    public init(root: PathType, path: String, pattern: String, recursive: Int = 0,
                uploadRoot: PathType? = nil, uploadPath: String? = nil) {
        self.root = root
        self.path = path
        self.pattern = pattern
        self.recursive = recursive
        self.uploadRoot = uploadRoot ?? root
        self.uploadPath = uploadPath ?? path
    }
}

public struct UFS: Codable, Equatable, Sendable {
    public let quota: Int
    public let maxNumFiles: Int
    public let saveFilePatterns: [SaveFilePattern]

    public init(quota: Int = 0, maxNumFiles: Int = 0, saveFilePatterns: [SaveFilePattern] = []) {
        self.quota = quota
        self.maxNumFiles = maxNumFiles
        self.saveFilePatterns = saveFilePatterns
    }
}

public struct AppInfo: Codable, Equatable, Sendable {
    public let appID: UInt32
    public let name: String
    public let type: String
    public let depots: [DepotInfo]
    public let branches: [String: UInt64]  // branch name -> buildid
    public let installDir: String
    public let dlcAppIDs: [UInt32]
    public let ufs: UFS
    public let launches: [AppLaunch]
    public let controllerSupport: String
    public init(appID: UInt32, name: String, type: String = "game", depots: [DepotInfo] = [], branches: [String: UInt64] = [:],
                installDir: String = "", dlcAppIDs: [UInt32] = [], ufs: UFS = .init(), launches: [AppLaunch] = [], controllerSupport: String = "") {
        self.appID = appID; self.name = name; self.type = type; self.depots = depots; self.branches = branches
        self.installDir = installDir; self.dlcAppIDs = dlcAppIDs; self.ufs = ufs; self.launches = launches
        self.controllerSupport = controllerSupport
    }
}

/// Raw launch metadata is preserved for source-side resolution; it is never executed as a shell command.
public struct AppLaunch: Codable, Equatable, Sendable {
    public let id: String
    public let executable: String
    public let arguments: String
    public let workingDirectory: String
    public let osList: String
    public let osArch: String
    public let type: String
    public let requiredDLC: UInt32?
    public let betaKey: String?
    public let description: String?
    public init(id: String, executable: String, arguments: String = "", workingDirectory: String = "",
                osList: String = "", osArch: String = "", type: String = "", requiredDLC: UInt32? = nil, betaKey: String? = nil,
                description: String? = nil) {
        self.id = id; self.executable = executable; self.arguments = arguments; self.workingDirectory = workingDirectory
        self.osList = osList; self.osArch = osArch; self.type = type; self.requiredDLC = requiredDLC
        self.betaKey = betaKey
        self.description = description
    }
    public var isWindows: Bool { osList.isEmpty || osList.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "windows" } }
}

public extension CMClient {

    /// PICS access tokens gate full appinfo for some (mostly owned) apps.
    func picsAccessTokens(appIDs: [UInt32]) async throws -> [UInt32: UInt64] {
        var req = CMsgClientPICSAccessTokenRequest()
        req.appids = appIDs
        let parts = try await jobRequest(.kEmsgClientPicsaccessTokenRequest, body: req)
        guard let data = parts.first else { return [:] }
        let resp = try CMsgClientPICSAccessTokenResponse(serializedBytes: data)
        return Dictionary(uniqueKeysWithValues: resp.appAccessTokens.map { ($0.appid, $0.accessToken) })
    }

    /// Fetches and parses appinfo for one app.
    func appInfo(appID: UInt32) async throws -> AppInfo {
        let tokens = try await picsAccessTokens(appIDs: [appID])
        var app = CMsgClientPICSProductInfoRequest.AppInfo()
        app.appid = appID
        if let token = tokens[appID] { app.accessToken = token }
        var req = CMsgClientPICSProductInfoRequest()
        req.apps = [app]

        let parts = try await jobRequest(.kEmsgClientPicsproductInfoRequest, body: req) { data in
            guard let resp = try? CMsgClientPICSProductInfoResponse(serializedBytes: data) else { return true }
            return !resp.responsePending
        }
        for data in parts {
            let resp = try CMsgClientPICSProductInfoResponse(serializedBytes: data)
            for appInfo in resp.apps where appInfo.appid == appID {
                var buffer = appInfo.buffer
                while buffer.last == 0 { buffer.removeLast() }
                guard let text = String(data: buffer, encoding: .utf8) else {
                    throw SteamError.protocolError("appinfo buffer is not UTF-8")
                }
                let vdf = try VDF.parse(text)
                guard let root = vdf["appinfo"] else {
                    throw SteamError.protocolError("appinfo VDF missing root")
                }
                return Self.parseAppInfo(appID: appID, root: root)
            }
        }
        throw SteamError.protocolError("PICS returned no info for app \(appID) (unknown or restricted)")
    }

    static func parseAppInfo(appID: UInt32, root: VDF) -> AppInfo {
        let common = root["common"]
        let name = common?["name"]?.stringValue ?? "app_\(appID)"
        let type = common?["type"]?.stringValue ?? "?"
        let installDir = root["config"]?["installdir"]?.stringValue ?? ""
        let dlcAppIDs = (root["extended"]?["listofdlc"]?.stringValue ?? common?["extended"]?["listofdlc"]?.stringValue ?? "")
            .split(separator: ",")
            .compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }

        let launches = root["config"]?["launch"]?.entries.map { id, value in
            AppLaunch(id: id, executable: value["executable"]?.stringValue ?? "",
                arguments: value["arguments"]?.stringValue ?? "", workingDirectory: value["workingdir"]?.stringValue ?? "",
                osList: value["config"]?["oslist"]?.stringValue ?? "", osArch: value["config"]?["osarch"]?.stringValue ?? "",
                type: value["type"]?.stringValue ?? "", requiredDLC: value["config"]?["ownsdlc"]?.stringValue.flatMap(UInt32.init),
                betaKey: value["config"]?["betakey"]?.stringValue, description: value["description"]?.stringValue)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending } ?? []
        var depots: [DepotInfo] = []
        var branches: [String: UInt64] = [:]
        if let depotsNode = root["depots"] {
            for (key, value) in depotsNode.entries {
                if key.caseInsensitiveCompare("branches") == .orderedSame {
                    for (branch, info) in value.entries {
                        branches[branch] = info["buildid"]?.uint64Value ?? 0
                    }
                    continue
                }
                guard let depotID = UInt32(key) else { continue }  // skip baselanguages etc.
                let config = value["config"]
                let publicManifest = value["manifests"]?["public"]
                let dlcAppID = value["dlcappid"]?.stringValue.flatMap(UInt32.init)
                // Old appinfo format: gid directly as string; new: dict {gid, size, download}
                let gid = publicManifest?["gid"]?.uint64Value ?? publicManifest?.uint64Value
                depots.append(DepotInfo(
                    id: depotID,
                    name: value["name"]?.stringValue ?? "depot \(depotID)",
                    osList: config?["oslist"]?.stringValue ?? "",
                    osArch: config?["osarch"]?.stringValue ?? "",
                    language: config?["language"]?.stringValue ?? "",
                    isSharedInstall: value["sharedinstall"]?.stringValue == "1",
                    isDLC: dlcAppID != nil,
                    dlcAppID: dlcAppID,
                    manifestGID: gid,
                    size: publicManifest?["size"]?.uint64Value ?? 0,
                    downloadSize: publicManifest?["download"]?.uint64Value ?? 0))
            }
        }
        depots.sort { $0.id < $1.id }
        return AppInfo(appID: appID, name: name, type: type, depots: depots, branches: branches,
                       installDir: installDir, dlcAppIDs: dlcAppIDs, ufs: parseUFS(root), launches: launches,
                       controllerSupport: common?["controller_support"]?.stringValue ?? "")
    }

    private struct RootOverride {
        let from: PathType
        let to: PathType
        let addPath: String
        let transforms: [(String, String)]
    }

    private static func parseUFS(_ root: VDF) -> UFS {
        guard let node = root["ufs"] else { return UFS() }
        let overrides: [RootOverride] = node["rootoverrides"]?.entries.compactMap { _, value in
            let os = value["os"]?.stringValue ?? ""
            let osList = value["oslist"]?.stringValue ?? ""
            guard os.caseInsensitiveCompare("Windows") == .orderedSame
                    || osList.split(separator: ",").contains(where: {
                        $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("windows") == .orderedSame
                    }) else { return nil }
            return RootOverride(
                from: PathType.from(value["root"]?.stringValue),
                to: PathType.from(value["useinstead"]?.stringValue),
                addPath: value["addpath"]?.stringValue ?? "",
                transforms: value["pathtransforms"]?.entries.map { _, transform in
                    (transform["find"]?.stringValue ?? "", transform["replace"]?.stringValue ?? "")
                } ?? [])
        } ?? []

        let patterns: [SaveFilePattern] = node["savefiles"]?.entries.compactMap { _, saveFile in
            let platforms = saveFile["platforms"]?.entries.compactMap { $0.1.stringValue?.lowercased() } ?? []
            if !platforms.isEmpty && !platforms.contains("windows") { return nil }
            let originalRoot = PathType.from(saveFile["root"]?.stringValue)
            let rawPath = saveFile["path"]?.stringValue ?? ""
            let originalPath = rawPath == "." || rawPath == "/" ? "" : rawPath
            let override = overrides.first { $0.from == originalRoot }
            var path = originalPath
            if let override {
                if !override.addPath.isEmpty {
                    let prefix = override.addPath.replacingOccurrences(of: "\\", with: "/")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    path = originalPath.isEmpty ? prefix : "\(prefix)/\(originalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
                }
                for (find, replace) in override.transforms where !find.isEmpty {
                    path = path.replacingOccurrences(of: find, with: replace)
                }
            }
            return SaveFilePattern(
                root: override?.to ?? originalRoot,
                path: path,
                pattern: saveFile["pattern"]?.stringValue ?? "",
                recursive: Int(saveFile["recursive"]?.stringValue ?? "0") ?? 0,
                uploadRoot: originalRoot,
                uploadPath: originalPath)
        } ?? []
        return UFS(quota: Int(node["quota"]?.stringValue ?? "0") ?? 0,
                   maxNumFiles: Int(node["maxnumfiles"]?.stringValue ?? "0") ?? 0,
                   saveFilePatterns: patterns)
    }

    // MARK: depot keys

    func depotKey(appID: UInt32, depotID: UInt32) async throws -> Data {
        if let key = depotKeyStore.load(depotID) { return key }
        var req = CMsgClientGetDepotDecryptionKey()
        req.depotID = depotID
        req.appID = appID
        let parts = try await jobRequest(.kEmsgClientGetDepotDecryptionKey, body: req)
        guard let data = parts.first else { throw SteamError.protocolError("no depot key response") }
        let resp = try CMsgClientGetDepotDecryptionKeyResponse(serializedBytes: data)
        let result = EResult(rawValue: resp.eresult)
        guard result == .ok else {
            throw SteamError.eresult(result, context: "depot key for \(depotID) (not owned?)")
        }
        depotKeyStore.save(resp.depotEncryptionKey, for: depotID)
        return resp.depotEncryptionKey
    }

    // MARK: manifest request code

    func manifestRequestCode(appID: UInt32, depotID: UInt32, manifestGID: UInt64,
                             branch: String = "public") async throws -> UInt64 {
        var req = CContentServerDirectory_GetManifestRequestCode_Request()
        req.appID = appID
        req.depotID = depotID
        req.manifestID = manifestGID
        req.appBranch = branch
        let resp = try await serviceMethod(
            "ContentServerDirectory.GetManifestRequestCode#1",
            request: req, responseType: CContentServerDirectory_GetManifestRequestCode_Response.self)
        guard resp.manifestRequestCode != 0 else {
            throw SteamError.download("manifest request code denied for depot \(depotID)")
        }
        return resp.manifestRequestCode
    }
}
