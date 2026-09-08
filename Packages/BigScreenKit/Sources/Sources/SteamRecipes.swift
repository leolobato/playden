import Foundation
import Domain
import SteamCore

/// Internal recipes are pinned by InstallPlan.recipeVersion. Store metadata never supplies
/// executable setup commands. New recipes do not silently change already resolved plans.
enum SteamRecipes {
    struct Step: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let executable: String
        let inputDirectory: String?
        let arguments: [String]
    }
    static func latestVersion(for gameID: GameID) -> Int { gameID == .init(source: "steam", value: "8870") ? 2 : 1 }
    static func steps(for gameID: GameID, version: Int) throws -> [Step] {
        if version == 1 { return [] }
        guard version == 2, gameID == .init(source: "steam", value: "8870") else {
            throw SteamPlanBuilder.failure("Resolve recipe", "This game's saved preparation recipe is not supported by this version of Big Screen.")
        }
        return [
            .init(id: "bioshock-vc2008-x86-1", title: "Visual C++ 2008", executable: "Binaries/Prerequisites/vcredist_x86_vs2008sp1.exe", inputDirectory: nil, arguments: ["/q", "/norestart"]),
            .init(id: "bioshock-vc2010-x86-1", title: "Visual C++ 2010", executable: "Binaries/Prerequisites/vcredist_x86_vs2010sp1.exe", inputDirectory: nil, arguments: ["/q", "/norestart"]),
            .init(id: "bioshock-directx-jun2010-1", title: "DirectX game components", executable: "Binaries/Prerequisites/directx_Jun2010_redist/DXSETUP.exe", inputDirectory: "Binaries/Prerequisites/directx_Jun2010_redist", arguments: ["/silent"])
        ]
    }
    static func inputs(_ step: Step, files: [DepotManifest.File]) throws -> [DepotManifest.File] {
        let matches = try files.filter { file in
            let path = try SteamPlanBuilder.relativePath(file.path).lowercased()
            return path == step.executable.lowercased() || step.inputDirectory.map { path.hasPrefix($0.lowercased() + "/") } == true
        }
        guard matches.contains(where: { $0.path.replacingOccurrences(of: "\\", with: "/").lowercased() == step.executable.lowercased() && !$0.isDirectory }),
              matches.allSatisfy({ !$0.isSymlink }) else {
            throw SteamPlanBuilder.failure("Resolve recipe", "The store content is missing a required game prerequisite. Try refreshing the library.")
        }
        return matches.filter { !$0.isDirectory }.sorted { $0.path < $1.path }
    }
}
