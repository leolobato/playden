import Foundation
import CryptoKit
import Domain
import EpicCore

/// What an Epic install plan remembers about its build. No credentials.
struct EpicPlanPayload: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var appName: String
    var namespace: String
    var catalogItemID: String
    var buildVersion: String
    var manifestSHA1: String
    /// Chunk CDN bases at resolve time; downloads ask the manifest API again for current ones.
    var baseURLs: [URL]
    var canRunOffline: Bool
    var requiresOwnershipToken: Bool
    var deploymentID: String?
}

/// Installs one Epic game: its manifest, chunk download, verification and launch arguments (PRD 09 §4–§5).
struct EpicInstaller: Installer {
    let game: SourceGameRecord
    let account: EpicAccount
    var gameID: GameID { game.id }

    /// Playden's own files inside the game folder: the manifest and ownership tokens.
    static let dataDirectory = ".playden-epic"
    static let recipeVersion = 1

    func resolve() async throws -> InstallPlan {
        let appName = game.id.value
        let (payload, manifest) = try await account.withSession { [api = account.api] session in
            let assets = try await api.assets(platform: .windows, accessToken: session.accessToken)
            guard let asset = assets.first(where: { $0.appName == appName }) else { throw SourceFailure.accessDenied }
            let item = try await api.catalogItem(namespace: asset.namespace, catalogItemID: asset.catalogItemId, accessToken: session.accessToken)
            if let store = item?.thirdPartyStore {
                throw OperationFailure(stage: "Resolve", reason: "This game is installed through \(store), which Playden can't run.", output: "")
            }
            let location = try await api.manifestLocation(platform: .windows, namespace: asset.namespace, catalogItemID: asset.catalogItemId,
                                                          appName: appName, accessToken: session.accessToken)
            let (manifest, _) = try await Self.manifest(at: location, api: api)
            let payload = EpicPlanPayload(appName: appName, namespace: asset.namespace, catalogItemID: asset.catalogItemId,
                                          buildVersion: manifest.meta.buildVersion, manifestSHA1: location.sha1, baseURLs: location.baseURLs,
                                          canRunOffline: item?.canRunOffline ?? true, requiresOwnershipToken: item?.requiresOwnershipToken ?? false,
                                          deploymentID: location.deploymentID)
            return (payload, (manifest, item?.additionalCommandLine))
        }
        let launchExe = manifest.0.meta.launchExe.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !launchExe.isEmpty else {
            throw OperationFailure(stage: "Resolve", reason: "This Epic item has no game to start. It may need another launcher.", output: "")
        }
        let folder = (launchExe as NSString).deletingLastPathComponent
        let arguments = Self.splitCommandLine(manifest.0.meta.launchCommand) + Self.splitCommandLine(manifest.1 ?? "")
        let installed = Int64(clamping: manifest.0.installSize)
        // Chunks still needed by later files can spill to disk while downloading.
        let estimate = InstallEstimate(downloadBytes: manifest.0.downloadSize, installedBytes: installed,
                                       requiredBytes: installed + min(Int64(512 << 20), manifest.0.downloadSize))
        return InstallPlan(game: game, manifestIDs: ["build": payload.buildVersion],
                           estimate: estimate,
                           launchSpec: LaunchSpec(executableRelativePath: launchExe, workingDirectoryRelativePath: folder.isEmpty ? "." : folder,
                                                  arguments: arguments),
                           sourcePayload: try JSONEncoder().encode(payload), recipeVersion: Self.recipeVersion, platform: .windows)
    }

    func download(_ plan: InstallPlan, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await write(plan, to: directory, only: nil, progress: progress)
    }

    func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?) async throws -> VerificationResult {
        try await verifyOriginals(plan, at: directory, staging: staging, progress: { _ in })
    }

    func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?,
                         progress: @escaping @Sendable (InstallFileVerification) -> Void) async throws -> VerificationResult {
        let payload = try Self.payload(plan)
        guard let manifest = try? Self.savedManifest(payload, in: directory) else { return VerificationResult(invalidFiles: [Self.dataDirectory]) }
        let invalid = try EpicDownloader(destination: directory).invalidFiles(in: manifest) { file, checked, total in
            progress(InstallFileVerification(file: file, bytesChecked: Int64(checked), bytesTotal: Int64(total), scope: .installation))
        }
        return VerificationResult(invalidFiles: invalid)
    }

    /// Downloads again only the files that are missing or changed.
    func repair(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?,
                progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        let result = try await verifyOriginals(plan, at: directory, staging: staging)
        guard !result.isValid else { return }
        let only = result.invalidFiles.contains(Self.dataDirectory) ? nil : Set(result.invalidFiles)
        try await write(plan, to: directory, only: only, progress: progress)
    }

    func postInstall(_ plan: InstallPlan, at directory: URL) async throws -> InstallStaging { InstallStaging() }

    /// The launch exe must exist. Manifest paths ignore case, so the saved path uses the spelling on disk.
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging) async throws -> LaunchSpec {
        var spec = plan.launchSpec
        guard let exe = Self.resolveCaseInsensitive(spec.executableRelativePath, in: directory) else {
            throw OperationFailure(stage: "Validate", reason: "The game's program \(spec.executableRelativePath) is missing. Verify files or reinstall.", output: "")
        }
        spec.executableRelativePath = exe
        let folder = (exe as NSString).deletingLastPathComponent
        spec.workingDirectoryRelativePath = folder.isEmpty ? "." : folder
        return spec
    }

    func uninstall(_ plan: InstallPlan, at directory: URL) async throws {}

    /// Appends the arguments the Epic launcher passes, with a sign-in code fetched just now (PRD 09 FR-EPIC-22…24).
    func prepareLaunch(_ spec: LaunchSpec, plan: InstallPlan, at directory: URL, offline: Bool) async throws -> LaunchSpec {
        let payload = try Self.payload(plan)
        let needsOnline = OperationFailure(stage: "Start game", reason: "Epic needs to be online to start this game.", output: "")
        var launch = spec
        do {
            if offline { throw SourceFailure.network }
            let (arguments, token) = try await account.withSession { [auth = account.auth, api = account.api] session in
                let code = try await auth.exchangeCode(accessToken: session.accessToken)
                let token = payload.requiresOwnershipToken
                    ? try await api.ownershipToken(accountID: session.accountID, namespace: payload.namespace,
                                                   catalogItemID: payload.catalogItemID, accessToken: session.accessToken)
                    : nil
                return (Self.launchArguments(payload, code: code, displayName: session.displayName, accountID: session.accountID), token)
            }
            launch.arguments += arguments
            if let token {
                let url = directory.appendingPathComponent("\(Self.dataDirectory)/\(payload.namespace)\(payload.catalogItemID).ovt")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try token.write(to: url, options: .atomic)
                launch.arguments.insert("-epicovt=Z:" + url.path.replacingOccurrences(of: "/", with: "\\"), at: launch.arguments.firstIndex(of: "-EpicPortal") ?? launch.arguments.endIndex)
            }
        } catch SourceFailure.network {
            guard payload.canRunOffline, !payload.requiresOwnershipToken else { throw needsOnline }
            launch.arguments += Self.launchArguments(payload, code: "", displayName: "", accountID: "")
        } catch let failure as SourceFailure where [.expired, .signedOut, .credentialsRejected].contains(failure) {
            throw OperationFailure(stage: "Sign-in expired", reason: "Sign in to Epic Games again to start this game.", output: "")
        }
        return launch
    }

    // MARK: Helpers

    static func launchArguments(_ payload: EpicPlanPayload, code: String, displayName: String, accountID: String) -> [String] {
        let locale = Locale.current.language.languageCode?.identifier ?? "en"
        return ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=\(code)", "-AUTH_TYPE=exchangecode", "-epicapp=\(payload.appName)", "-epicenv=Prod",
                "-EpicPortal", "-epicusername=\(displayName)", "-epicuserid=\(accountID)", "-epiclocale=\(locale)",
                "-epicsandboxid=\(payload.namespace)"] + (payload.deploymentID.map { ["-epicdeploymentid=\($0)"] } ?? [])
    }

    private func write(_ plan: InstallPlan, to directory: URL, only: Set<String>?, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        let payload = try Self.payload(plan)
        let (manifest, location) = try await account.withSession { [api = account.api] session in
            let location = try await api.manifestLocation(platform: .windows, namespace: payload.namespace, catalogItemID: payload.catalogItemID,
                                                          appName: payload.appName, accessToken: session.accessToken)
            guard location.sha1 == payload.manifestSHA1 else {
                throw OperationFailure(stage: "Download", reason: "Epic has a newer version of this game. Cancel and install it again.", output: "")
            }
            if let saved = try? Self.savedManifest(payload, in: directory) { return (saved, location) }
            let (manifest, raw) = try await Self.manifest(at: location, api: api)
            try Self.saveManifest(raw, secrets: location.secrets, in: directory)
            return (manifest, location)
        }
        let fetcher = account.api.chunkFetcher(baseURLs: location.baseURLs.isEmpty ? payload.baseURLs : location.baseURLs)
        let sequence = ProgressSequence()
        var downloader = EpicDownloader(destination: directory)
        downloader.onProgress = { update in
            progress(InstallProgress(bytesCompleted: Int64(update.bytesDone), bytesTotal: Int64(update.bytesTotal), currentFile: update.file,
                                     downloadedBytes: Int64(update.bytesDownloaded), freshlyWrittenBytes: Int64(update.bytesWritten),
                                     sequence: sequence.next()))
        }
        do { try await downloader.download(manifest, secrets: location.secrets, only: only, fetch: fetcher.fetch) }
        catch { throw EpicAccount.failure(error) }
    }

    static func payload(_ plan: InstallPlan) throws -> EpicPlanPayload {
        guard let payload = try? JSONDecoder().decode(EpicPlanPayload.self, from: plan.sourcePayload),
              payload.version == EpicPlanPayload.currentVersion else {
            throw OperationFailure(stage: "Install plan", reason: "This install plan is from another Playden version. Install the game again.", output: "")
        }
        return payload
    }

    static func manifest(at location: EpicManifestLocation, api: EpicLibraryAPI) async throws -> (EpicManifest, Data) {
        do { return try await api.manifest(at: location) }
        catch EpicError.missingKey { throw OperationFailure(stage: "Resolve", reason: "This game isn't released yet.", output: "") }
    }

    private struct SavedManifest: Codable { var secrets: [String: String] }

    static func saveManifest(_ raw: Data, secrets: [String: String], in directory: URL) throws {
        let folder = directory.appendingPathComponent(dataDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try raw.write(to: folder.appendingPathComponent("build.manifest"), options: .atomic)
        try JSONEncoder().encode(SavedManifest(secrets: secrets)).write(to: folder.appendingPathComponent("build.json"), options: .atomic)
    }

    static func savedManifest(_ payload: EpicPlanPayload, in directory: URL) throws -> EpicManifest {
        let folder = directory.appendingPathComponent(dataDirectory, isDirectory: true)
        let raw = try Data(contentsOf: folder.appendingPathComponent("build.manifest"))
        guard Insecure.SHA1.hash(data: raw).map({ String(format: "%02x", $0) }).joined() == payload.manifestSHA1 else {
            throw OperationFailure(stage: "Verify", reason: "The saved build manifest doesn't match this install.", output: "")
        }
        let saved = (try? JSONDecoder().decode(SavedManifest.self, from: Data(contentsOf: folder.appendingPathComponent("build.json")))) ?? SavedManifest(secrets: [:])
        return try EpicManifest.parse(raw, secrets: saved.secrets)
    }

    /// Splits a launch command the way the Epic launcher does: on spaces, keeping quoted runs together.
    static func splitCommandLine(_ line: String) -> [String] {
        var parts: [String] = [], current = "", quoted = false, started = false
        for character in line {
            if character == "\"" { quoted.toggle(); started = true; continue }
            if character.isWhitespace && !quoted {
                if started { parts.append(current); current = ""; started = false }
                continue
            }
            current.append(character); started = true
        }
        if started { parts.append(current) }
        return parts
    }

    /// Finds `path` under `root`, matching each component without regard to case.
    static func resolveCaseInsensitive(_ path: String, in root: URL) -> String? {
        var resolved: [String] = []
        var folder = root
        for component in path.split(separator: "/").map(String.init) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                  let match = names.first(where: { $0 == component }) ?? names.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame })
            else { return nil }
            resolved.append(match); folder.appendPathComponent(match)
        }
        var isDirectory: ObjCBool = false
        guard !resolved.isEmpty, FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return resolved.joined(separator: "/")
    }
}

private final class ProgressSequence: @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt64 = 0
    func next() -> UInt64 { lock.withLock { value += 1; return value } }
}
