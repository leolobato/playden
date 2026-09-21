import Foundation
import Domain
import SteamCore

// Decode only the Cloud declaration. Depot manifests and launch configuration are
// irrelevant to this display hint; actual save operations still use saveMapping.
private struct SteamCloudDeclaration: Decodable {
    struct App: Decodable {
        let appID: UInt32
        let ufs: UFS
    }
    let version: Int
    let app: App
}

extension SteamInstaller {
    public func supportsCloudSaves(_ plan: InstallPlan) throws -> Bool {
        guard plan.game.id == gameID, gameID.source == "steam", plan.language == "english" else {
            throw SteamPlanBuilder.failure("Cloud availability", "The saved plan is for a different game or version.")
        }
        let declaration = try JSONDecoder().decode(SteamCloudDeclaration.self, from: plan.sourcePayload)
        guard declaration.version == 1, String(declaration.app.appID) == gameID.value else {
            throw SteamPlanBuilder.failure("Cloud availability", "The saved Cloud declaration is invalid.")
        }
        let mapping = SteamSaveMapping.build(declaration.app.ufs, appID: declaration.app.appID)
        return mapping.coverage != .unknown && mapping.unresolved.isEmpty && mapping.rules.contains { $0.cloudPrefix != nil }
    }

    public func saveMapping(_ plan: InstallPlan) throws -> SaveMapping {
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        return SteamSaveMapping.build(payload.app.ufs, appID: payload.app.appID)
    }
}

enum SteamSaveMapping {
    static func build(_ ufs: UFS, appID: UInt32? = nil) -> SaveMapping {
        // This is the exact synthetic-account save root written by SteamInstaller.postInstall.
        // It retains GBE remote-storage files and settings, but is not itself a Cloud mapping.
        var rules = [SaveRule(root: .bottle, directory: "drive_c/Program Files (x86)/Steam/userdata/0")]
        // GBE's local_save_path is account-scoped; it appends appid/remote for the
        // ISteamRemoteStorage API. Bare Cloud filenames belong here, independently
        // of Auto-Cloud's Documents/AppData rules (some games use both).
        let remoteDirectory = appID.map { "drive_c/Program Files (x86)/Steam/userdata/0/\($0)/remote" }
        if let remoteDirectory, ufs.quota > 0 || ufs.maxNumFiles > 0 || !ufs.saveFilePatterns.isEmpty {
            rules.append(.init(root: .bottle, directory: remoteDirectory, cloudPrefix: ""))
        }
        var unresolved: [String] = []
        for item in ufs.saveFilePatterns {
            let localBase = item.root == .SteamUserData ? remoteDirectory.map { (SaveRoot.bottle, $0) } : base(item.root)
            guard let base = localBase, let path = relative(item.path, accountTokens: true),
                  let uploadPath = relative(item.uploadPath, accountTokens: true), item.uploadRoot.isWindows,
                  validPattern(item.pattern), item.recursive == 0 || item.recursive == 1 else {
                unresolved.append("A Steam save location needs a verified game recipe.")
                continue
            }
            let directory = [base.1, path].filter { !$0.isEmpty }.joined(separator: "/")
            let prefix = item.uploadRoot == .SteamUserData ? uploadPath : "%\(item.uploadRoot.rawValue)%" + uploadPath
            let rule = SaveRule(root: base.0, directory: directory, pattern: item.pattern,
                                recursive: item.recursive == 1, cloudPrefix: prefix)
            if !rules.contains(rule) { rules.append(rule) }
            // Retain all existing account folders in local backups, even before account resolution.
            // Only the explicitly resolved account rule participates in Cloud synchronization.
            if let token = directory.range(of: "{64BitSteamID}") ?? directory.range(of: "{Steam3AccountID}") {
                let parent = String(directory[..<token.lowerBound].split(separator: "/").dropLast(directory[..<token.lowerBound].hasSuffix("/") ? 0 : 1).joined(separator: "/"))
                if !parent.isEmpty {
                    let retained = SaveRule(root: base.0, directory: parent)
                    if !rules.contains(retained) { rules.append(retained) }
                }
            }
        }
        if !rules.contains(where: { $0.cloudPrefix != nil }) { unresolved.append("Steam does not specify this game's save locations.") }
        return SaveMapping(rules: rules, coverage: unresolved.isEmpty ? .metadata : .unknown,
                           unresolved: Array(Set(unresolved)).sorted())
    }
    private static func base(_ root: PathType) -> (SaveRoot, String)? {
        switch root {
        case .GameInstall: return (.game, "")
        case .WinMyDocuments: return (.bottle, ".playden-folders/Documents")
        case .WinAppDataLocal: return (.bottle, "drive_c/users/crossover/AppData/Local")
        case .WinAppDataLocalLow: return (.bottle, "drive_c/users/crossover/AppData/LocalLow")
        case .WinAppDataRoaming: return (.bottle, "drive_c/users/crossover/AppData/Roaming")
        case .WinSavedGames: return (.bottle, "drive_c/users/crossover/Saved Games")
        case .WinProgramData: return (.bottle, "drive_c/ProgramData")
        case .Root: return (.bottle, "drive_c/users/crossover")
        // Non-Windows paths cannot be resolved inside this Windows bottle.
        default: return nil
        }
    }
    private static func relative(_ raw: String, accountTokens: Bool = false) -> String? {
        var path = raw.replacingOccurrences(of: "\\", with: "/")
        // Steam directory declarations may end in separators (for example FFVII
        // Remake). Reject absolute paths before removing those trailing separators.
        guard !path.hasPrefix("/") else { return nil }
        while path.hasSuffix("/") { path.removeLast() }
        let checked = accountTokens ? path.replacingOccurrences(of: "{64BitSteamID}", with: "0").replacingOccurrences(of: "{Steam3AccountID}", with: "0") : path
        guard !path.hasPrefix("/"), !path.contains(where: { $0.isNewline || $0 == "\0" }),
              checked.rangeOfCharacter(from: CharacterSet(charactersIn: ":{}%*?")) == nil else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.isEmpty || parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return path
    }
    private static func validPattern(_ value: String) -> Bool {
        !value.isEmpty && value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\0:[]{}")) == nil
            && !value.contains(where: \.isNewline) && value != "." && value != ".."
    }
}
