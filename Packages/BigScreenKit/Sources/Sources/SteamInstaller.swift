import Foundation
import CryptoKit
import Domain
import SteamCore

public struct SteamInstaller: Installer {
    public var gameID: GameID { game.id }
    private let game: SourceGameRecord
    private let backend: any SteamInstallBackend
    public init(game: SourceGameRecord, account: SteamAccount) {
        self.game = game; backend = LiveSteamInstallBackend(account: account)
    }
    init(game: SourceGameRecord, backend: any SteamInstallBackend) { self.game = game; self.backend = backend }
    public func resolve() async throws -> InstallPlan {
        guard gameID.source == "steam", let appID = UInt32(gameID.value) else { throw SourceFailure.malformedResponse }
        let resolved = try await backend.resolve(appID: appID)
        return try SteamPlanBuilder.build(game: game, app: resolved.app, manifests: resolved.manifests, ownedApps: resolved.entitlements.appIDs)
    }
    public func download(_ plan: InstallPlan, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await backend.download(SteamPlanBuilder.payload(plan, for: gameID), to: directory, progress: progress)
    }
    public func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?) async throws -> VerificationResult {
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        let replacements = try replacements(staging ?? InstallStaging(), payload: payload)
        var invalid: [String] = []
        for manifest in payload.manifests {
            try Task.checkCancellation()
            let mapped = try manifest.files.map { file in
                let path = try SteamPlanBuilder.relativePath(file.path)
                return DepotManifest.File(path: replacements[path] ?? path, size: file.size, flags: file.flags,
                    linkTarget: file.linkTarget, chunks: file.chunks, contentSHA1: file.contentSHA1)
            }
            let result = try ResumableDepotDownload(destination: directory).invalidFiles(in: DepotManifest(depotID: manifest.depotID, gid: manifest.gid, files: mapped, totalSize: manifest.totalSize))
            invalid += result.map { path in replacements.first(where: { $0.value == path })?.key ?? path }
        }
        return VerificationResult(invalidFiles: invalid)
    }
    public func postInstall(_ plan: InstallPlan, at directory: URL) async throws -> InstallStaging {
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        try Task.checkCancellation()
        try rejectLinks(in: directory)
        let apis = try apiPaths(payload)
        // Existing .orig files are usable only if they still verify against the pinned manifest.
        // This recovers an interrupted staging pass even before its receipt reached Catalog.
        let recovered = InstallStaging(mutations: apis.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0 + ".orig").path) }.map {
            FileMutation(relativePath: $0, originalRelativePath: $0 + ".orig", stagedSHA256: Data(repeating: 0, count: 32))
        })
        guard try await verifyOriginals(plan, at: directory, staging: recovered).isValid else {
            throw SteamPlanBuilder.failure("Prepare", "Original game files must be repaired before preparation can continue.")
        }
        // Detect unsupported unpacking before modifying anything, including for games without an API DLL.
        for file in payload.manifests.flatMap(\.files) where file.path.lowercased().hasSuffix(".exe") {
            let executable = directory.appendingPathComponent(try SteamPlanBuilder.relativePath(file.path))
            if try PEInspector.inspect(executable).requiresSteamStubRuntime {
                throw SteamPlanBuilder.failure("Prepare", "This game requires SteamStub unpacking before it can launch.")
            }
        }
        guard !apis.isEmpty else { return InstallStaging() }
        let preparer = try SteamPreparer(assets: GBEAssets.bundled())
        let metadata = PrepareMetadata(installDir: payload.app.installDir, installedDepotIDs: payload.manifests.map(\.depotID),
            dlcAppIDs: payload.ownedDLC, forceDLC: false, ufs: payload.app.ufs)
        let result = try preparer.prepare(appID: payload.app.appID, gameDirectory: directory,
            account: PrepareAccount(accountName: "Big Screen", steamID: 0), metadata: metadata, offline: true)
        guard result.steamStubRequirements.isEmpty else {
            throw SteamPlanBuilder.failure("Prepare", "This game requires SteamStub unpacking before it can launch. Its original files are preserved.")
        }
        var mutations: [FileMutation] = []
        let canonicalRoot = directory.resolvingSymlinksInPath().path + "/"
        for dll in result.dlls {
            let stagedPath = dll.dll.resolvingSymlinksInPath().path
            let backupPath = dll.backup.resolvingSymlinksInPath().path
            guard stagedPath.hasPrefix(canonicalRoot), backupPath.hasPrefix(canonicalRoot) else {
                throw SteamPlanBuilder.failure("Prepare", "A prepared file leaves the installation folder.")
            }
            // Steam's offline status alone still starts GBE's LAN discovery. Big Screen v1
            // uses offline play, so do not request local-network access just by launching it.
            let connectivity = dll.dll.deletingLastPathComponent().appendingPathComponent("steam_settings/configs.main.ini")
            try "[main::connectivity]\ndisable_lan_only=0\noffline=1\ndisable_networking=1\n".write(to: connectivity, atomically: true, encoding: .utf8)
            let relative = String(stagedPath.dropFirst(canonicalRoot.count))
            let backup = String(backupPath.dropFirst(canonicalRoot.count))
            mutations.append(FileMutation(relativePath: relative, originalRelativePath: backup, stagedSHA256: try digest(dll.dll)))
        }
        return InstallStaging(mutations: mutations, dllOverrides: Array(Set(result.dlls.map { $0.dll.deletingPathExtension().lastPathComponent.lowercased() + "=n,b" })).sorted())
    }
    public func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging) async throws -> LaunchSpec {
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        try rejectLinks(in: directory)
        guard Set(try apiPaths(payload)) == Set(staging.mutations.map(\.relativePath)) else {
            throw SteamPlanBuilder.failure("Verify", "Game preparation is incomplete.")
        }
        let verification = try await verifyOriginals(plan, at: directory, staging: staging)
        guard verification.isValid else { throw SteamPlanBuilder.failure("Verify", "Some game files are missing or damaged. Verify files to repair them.") }
        for mutation in staging.mutations {
            let path = try SteamPlanBuilder.relativePath(mutation.relativePath)
            guard try digest(directory.appendingPathComponent(path)) == mutation.stagedSHA256 else { throw SteamPlanBuilder.failure("Verify", "A prepared game file changed unexpectedly.") }
        }
        let executable = directory.appendingPathComponent(try SteamPlanBuilder.relativePath(plan.launchSpec.executableRelativePath))
        guard try !PEInspector.inspect(executable).requiresSteamStubRuntime else {
            throw SteamPlanBuilder.failure("Verify", "The game executable still requires SteamStub unpacking.")
        }
        var spec = plan.launchSpec; spec.dllOverrides = staging.dllOverrides
        return spec
    }
    public func uninstall(_ plan: InstallPlan, at directory: URL) async throws {
        _ = try SteamPlanBuilder.payload(plan, for: gameID)
        try Task.checkCancellation()
        // Steam has no separate source-side uninstall operation; the owned directory is removed by
        // Installs only after save retention, and the app's cached plan is deleted transactionally.
    }
    private func digest(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty else { break }
            hash.update(data: bytes)
        }
        return Data(hash.finalize())
    }
    private func apiPaths(_ payload: SteamInstallPayload) throws -> [String] {
        try payload.manifests.flatMap(\.files).filter { !$0.isDirectory && !$0.isSymlink }.map {
            try SteamPlanBuilder.relativePath($0.path)
        }.filter { ["steam_api.dll", "steam_api64.dll"].contains(($0 as NSString).lastPathComponent.lowercased()) }.sorted()
    }
    private func replacements(_ staging: InstallStaging, payload: SteamInstallPayload) throws -> [String: String] {
        let allowed = Set(try apiPaths(payload))
        let manifestPaths = Set(try payload.manifests.flatMap(\.files).map { try SteamPlanBuilder.relativePath($0.path).lowercased() })
        var result: [String: String] = [:]
        guard staging.version == 1 else { throw SteamPlanBuilder.failure("Verify", "Unsupported preparation receipt version.") }
        for mutation in staging.mutations {
            guard allowed.contains(mutation.relativePath), mutation.originalRelativePath == mutation.relativePath + ".orig",
                  !manifestPaths.contains(mutation.originalRelativePath.lowercased()), mutation.stagedSHA256.count == 32,
                  result.updateValue(mutation.originalRelativePath, forKey: mutation.relativePath) == nil else {
                throw SteamPlanBuilder.failure("Verify", "The preparation receipt contains an invalid original-file mapping.")
            }
        }
        let expected = Set(staging.mutations.map { ($0.relativePath as NSString).lastPathComponent.lowercased().replacingOccurrences(of: ".dll", with: "=n,b") })
        guard staging.dllOverrides.isEmpty || Set(staging.dllOverrides) == expected else {
            throw SteamPlanBuilder.failure("Verify", "The preparation receipt contains unexpected runtime overrides.")
        }
        return result
    }
    private func rejectLinks(in directory: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        var enumerationError: Error?
        guard try directory.resourceValues(forKeys: Set(keys)).isSymbolicLink != true,
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, errorHandler: { _, error in enumerationError = error; return false }) else {
            throw SteamPlanBuilder.failure("Prepare", "The game directory is unavailable.")
        }
        for case let file as URL in files {
            try Task.checkCancellation()
            if try file.resourceValues(forKeys: Set(keys)).isSymbolicLink == true {
                throw SteamPlanBuilder.failure("Prepare", "This game uses linked files that need a preparation recipe.")
            }
        }
        if let enumerationError { throw enumerationError }
    }
}
