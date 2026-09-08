import Foundation
import Domain
import SteamCore

extension SteamInstaller {
    public func saveMapping(_ plan: InstallPlan) throws -> SaveMapping {
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        return SteamSaveMapping.build(payload.app.ufs)
    }
}

enum SteamSaveMapping {
    static func build(_ ufs: UFS) -> SaveMapping {
        // This is the exact synthetic-account save root written by SteamInstaller.postInstall.
        // It retains GBE remote-storage files and settings, but is not itself a Cloud mapping.
        var rules = [SaveRule(root: .bottle, directory: "drive_c/Program Files (x86)/Steam/userdata/0")]
        var unresolved: [String] = []
        for item in ufs.saveFilePatterns {
            guard let base = base(item.root), let path = relative(item.path),
                  let uploadPath = relative(item.uploadPath), item.uploadRoot.isWindows,
                  validPattern(item.pattern), item.recursive == 0 || item.recursive == 1 else {
                unresolved.append("A Steam save location needs a verified game recipe.")
                continue
            }
            let directory = [base.1, path].filter { !$0.isEmpty }.joined(separator: "/")
            let prefix = "%\(item.uploadRoot.rawValue)%" + uploadPath
            let rule = SaveRule(root: base.0, directory: directory, pattern: item.pattern,
                                recursive: item.recursive == 1, cloudPrefix: prefix)
            if !rules.contains(rule) { rules.append(rule) }
        }
        if ufs.saveFilePatterns.isEmpty { unresolved.append("Steam does not specify this game's save locations.") }
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
        // Account placeholders, raw roots and Steam API storage need an explicit recipe/identity.
        default: return nil
        }
    }
    private static func relative(_ raw: String) -> String? {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.contains(where: { $0.isNewline || $0 == "\0" }),
              path.rangeOfCharacter(from: CharacterSet(charactersIn: ":{}%*?")) == nil else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.isEmpty || parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return path
    }
    private static func validPattern(_ value: String) -> Bool {
        !value.isEmpty && value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\0:[]{}")) == nil
            && !value.contains(where: \.isNewline) && value != "." && value != ".."
    }
}
