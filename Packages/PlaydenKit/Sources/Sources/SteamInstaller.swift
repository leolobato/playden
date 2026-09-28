import Foundation
import CryptoKit
import Domain
import SteamCore

public struct SteamInstaller: Installer {
    public var gameID: GameID { game.id }
    private let game: SourceGameRecord
    private let backend: any SteamInstallBackend
    private let runtimeTools: (any RuntimeToolRunning)?
    /// Steam emulator saves for Mac builds, per app; outside game folders so uninstall keeps them.
    let emulatorSaves: URL
    let codeSigner: any CodeSigning
    public init(game: SourceGameRecord, account: SteamAccount, runtimeTools: (any RuntimeToolRunning)? = nil,
                emulatorSaves: URL = SteamInstaller.defaultEmulatorSaves) {
        self.game = game; backend = LiveSteamInstallBackend(account: account)
        self.runtimeTools = runtimeTools; self.emulatorSaves = emulatorSaves; codeSigner = AdHocCodeSigner()
    }
    init(game: SourceGameRecord, backend: any SteamInstallBackend, runtimeTools: (any RuntimeToolRunning)? = nil,
         emulatorSaves: URL = SteamInstaller.defaultEmulatorSaves, codeSigner: any CodeSigning = AdHocCodeSigner()) {
        self.game = game; self.backend = backend; self.runtimeTools = runtimeTools
        self.emulatorSaves = emulatorSaves; self.codeSigner = codeSigner
    }
    public static var defaultEmulatorSaves: URL { AppPaths.supportRoot().appendingPathComponent("Steam Emulator", isDirectory: true) }
    public func resolve() async throws -> InstallPlan { try await resolve(platform: .windows) }
    public func resolve(platform: GamePlatform) async throws -> InstallPlan {
        guard gameID.source == SourceID.steam, let appID = UInt32(gameID.value) else { throw SourceFailure.malformedResponse }
        let resolved = try await backend.resolve(appID: appID, platform: platform)
        return try SteamPlanBuilder.build(game: game, app: resolved.app, manifests: resolved.manifests,
            ownedApps: resolved.entitlements.appIDs, ownedDepots: resolved.entitlements.depotIDs, platform: platform)
    }
    public func download(_ plan: InstallPlan, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await backend.download(SteamPlanBuilder.payload(plan, for: gameID), to: directory, progress: progress)
    }
    public func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?) async throws -> VerificationResult {
        try await verifyOriginals(plan, at: directory, staging: staging, progress: { _ in })
    }
    public func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?,
        progress: @escaping @Sendable (InstallFileVerification) -> Void) async throws -> VerificationResult {
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        let replacements = try replacements(staging ?? InstallStaging(), payload: payload)
        let total = try verificationBytes(payload)
        var completed: Int64 = 0
        var invalid: [String] = []
        progress(.init(file: "", bytesChecked: 0, bytesTotal: total, scope: .installation))
        for manifest in payload.manifests {
            try Task.checkCancellation()
            let mapped = try manifest.files.map { file in
                let path = try SteamPlanBuilder.relativePath(file.path)
                return DepotManifest.File(path: replacements[path] ?? path, size: file.size, flags: file.flags,
                    linkTarget: file.linkTarget, chunks: file.chunks, contentSHA1: file.contentSHA1)
            }
            let result = try ResumableDepotDownload(destination: directory).invalidFiles(in: DepotManifest(depotID: manifest.depotID, gid: manifest.gid, files: mapped, totalSize: manifest.totalSize)) { file, checked, _ in
                progress(.init(file: replacements.first(where: { $0.value == file })?.key ?? file,
                    bytesChecked: completed + Int64(checked), bytesTotal: total, scope: .installation))
            }
            completed += mapped.filter { !$0.isDirectory && !$0.isSymlink }.reduce(Int64(0)) { $0 + Int64($1.size) }
            progress(.init(file: "", bytesChecked: completed, bytesTotal: total, scope: .installation))
            invalid += result.map { path in replacements.first(where: { $0.value == path })?.key ?? path }
        }
        return VerificationResult(invalidFiles: invalid)
    }
    public func postInstall(_ plan: InstallPlan, at directory: URL) async throws -> InstallStaging {
        try await prepare(plan, at: directory, bottle: nil)
    }
    public func preparePrerequisites(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle) async throws {
        try await SteamPrerequisites.prepare(plan, gameID: gameID, at: directory, in: bottle, tools: runtimeTools,
            validateDirectory: { try rejectLinks(in: directory) })
    }
    public func postInstall(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle) async throws -> InstallStaging {
        guard bottle.gameID == gameID else { throw SteamPlanBuilder.failure("Prepare", "The game runtime belongs to another installation.") }
        return try await prepare(plan, at: directory, bottle: bottle)
    }
    public func postInstall(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle,
        progress: @escaping @Sendable (InstallPreparationProgress) -> Void) async throws -> InstallStaging {
        guard bottle.gameID == gameID else { throw SteamPlanBuilder.failure("Prepare", "The game runtime belongs to another installation.") }
        return try await prepare(plan, at: directory, bottle: bottle, progress: progress)
    }
    private func prepare(_ plan: InstallPlan, at directory: URL, bottle: GameBottle?,
        progress: @escaping @Sendable (InstallPreparationProgress) -> Void = { _ in }) async throws -> InstallStaging {
        let reporter = PreparationReporter(progress)
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        try Task.checkCancellation()
        if payload.platform == .macOS { return try await prepareMac(plan, payload: payload, at: directory, reporter: reporter) }
        try rejectLinks(in: directory)
        let apis = try apiPaths(payload)
        // Existing .orig files are usable only if they still verify against the pinned manifest.
        // This recovers an interrupted staging pass even before its receipt reached Catalog.
        let executables = try executablePaths(payload)
        let recovered = InstallStaging(mutations: (apis + executables).filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0 + ".orig").path) }.map {
            FileMutation(relativePath: $0, originalRelativePath: $0 + ".orig", stagedSHA256: Data(repeating: 0, count: 32))
        }, version: 2)
        guard try await verifyOriginals(plan, at: directory, staging: recovered, progress: { reporter.report(.verifying($0)) }).isValid else {
            throw SteamPlanBuilder.failure("Prepare", "Original game files must be repaired before preparation can continue.")
        }
        var mutations: [FileMutation] = []
        let manifestPaths = Set(try payload.manifests.flatMap(\.files).map { try SteamPlanBuilder.relativePath($0.path).lowercased() })
        for path in executables {
            reporter.report(.preparingExecutable(path))
            let executable = directory.appendingPathComponent(path), backup = directory.appendingPathComponent(path + ".orig")
            let original = FileManager.default.fileExists(atPath: backup.path) ? backup : executable
            guard try PEInspector.inspect(original).requiresSteamStubRuntime else { continue }
            guard let bottle, let runtimeTools else {
                throw SteamPlanBuilder.failure("Prepare", "This game needs executable preparation in its owned runtime. Retry installation in Playden.")
            }
            guard !manifestPaths.contains((path + ".orig").lowercased()) else {
                throw SteamPlanBuilder.failure("Prepare", "The executable backup would replace an original game file. Its files have been kept.")
            }
            let originalHash = try digest(original)
            if original == executable { try FileManager.default.copyItem(at: executable, to: backup) }
            let unpacked = try await SteamUnpacking.unpack(backup, in: bottle, tools: runtimeTools)
            try Task.checkCancellation()
            try rejectLinks(in: directory)
            guard try digest(backup) == originalHash else { throw SteamPlanBuilder.failure("Prepare", "The original executable changed during preparation. Verify files before retrying.") }
            try unpacked.write(to: executable, options: .atomic)
            mutations.append(.init(relativePath: path, originalRelativePath: path + ".orig", stagedSHA256: Data(SHA256.hash(data: unpacked))))
        }
        guard !apis.isEmpty else { return InstallStaging(mutations: mutations, version: mutations.isEmpty ? 1 : 2) }
        reporter.report(.applyingSettings)
        let preparer = try SteamPreparer(assets: GBEAssets.bundled())
        let metadata = PrepareMetadata(installDir: payload.app.installDir, installedDepotIDs: payload.manifests.map(\.depotID),
            dlcAppIDs: payload.ownedDLC, forceDLC: false, ufs: payload.app.ufs)
        let result = try preparer.prepare(appID: payload.app.appID, gameDirectory: directory,
            account: PrepareAccount(accountName: "Playden", steamID: 0), metadata: metadata, offline: true)
        guard result.steamStubRequirements.isEmpty else {
            throw SteamPlanBuilder.failure("Prepare", "This game requires SteamStub unpacking before it can launch. Its original files are preserved.")
        }
        let stagingVersion = mutations.isEmpty ? 1 : 2
        let canonicalRoot = directory.resolvingSymlinksInPath().path + "/"
        for dll in result.dlls {
            let stagedPath = dll.dll.resolvingSymlinksInPath().path
            let backupPath = dll.backup.resolvingSymlinksInPath().path
            guard stagedPath.hasPrefix(canonicalRoot), backupPath.hasPrefix(canonicalRoot) else {
                throw SteamPlanBuilder.failure("Prepare", "A prepared file leaves the installation folder.")
            }
            // Steam's offline status alone still starts GBE's LAN discovery. Playden v1
            // uses offline play, so do not request local-network access just by launching it.
            let connectivity = dll.dll.deletingLastPathComponent().appendingPathComponent("steam_settings/configs.main.ini")
            try SteamSettingsINI.write("[main::connectivity]\ndisable_lan_only=0\noffline=1\ndisable_networking=1\n", to: connectivity)
            let relative = String(stagedPath.dropFirst(canonicalRoot.count))
            let backup = String(backupPath.dropFirst(canonicalRoot.count))
            mutations.append(FileMutation(relativePath: relative, originalRelativePath: backup, stagedSHA256: try digest(dll.dll)))
        }
        return InstallStaging(mutations: mutations, dllOverrides: Array(Set(result.dlls.map { $0.dll.deletingPathExtension().lastPathComponent.lowercased() + "=n,b" })).sorted(), version: stagingVersion)
    }
    public func repair(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?,
                       progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        let mappings = try replacements(staging ?? InstallStaging(), payload: payload)
        try checkLinks(in: directory, payload: payload)
        guard try await !verifyOriginals(plan, at: directory, staging: staging).isValid else { return }
        // Download originals to their verified backup paths. Leave the staged DLLs and save
        // directories in place; postInstall will reapply preparation after all originals verify.
        let manifests = try payload.manifests.map { manifest in
            let files = try manifest.files.map { file in
                let path = try SteamPlanBuilder.relativePath(file.path)
                return DepotManifest.File(path: mappings[path] ?? path, size: file.size, flags: file.flags,
                    linkTarget: file.linkTarget, chunks: file.chunks, contentSHA1: file.contentSHA1)
            }
            return DepotManifest(depotID: manifest.depotID, gid: manifest.gid, files: files, totalSize: manifest.totalSize)
        }
        try await backend.download(SteamInstallPayload(app: payload.app, manifests: manifests, ownedDLC: payload.ownedDLC,
                                   authorizedDepotIDs: payload.authorizedDepotIDs),
                                   to: directory, progress: progress)
    }
    public func launchOptions(_ plan: InstallPlan) throws -> [LaunchOption] {
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        return try SteamPlanBuilder.launchOptions(payload.app, files: payload.manifests.flatMap(\.files),
            ownedApps: Set(payload.ownedDLC + [payload.app.appID]), platform: payload.platform ?? .windows)
    }
    public func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging) async throws -> LaunchSpec {
        try await validate(plan, at: directory, staging: staging, progress: { _ in })
    }
    public func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging,
        progress: @escaping @Sendable (InstallFileVerification) -> Void) async throws -> LaunchSpec {
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        if payload.platform == .macOS { return try await validateMac(plan, payload: payload, at: directory, staging: staging, progress: progress) }
        try rejectLinks(in: directory)
        let apis = Set(try apiPaths(payload)), executables = Set(try executablePaths(payload)), changed = Set(staging.mutations.map(\.relativePath))
        guard apis.isSubset(of: changed), changed.isSubset(of: apis.union(executables)) else {
            throw SteamPlanBuilder.failure("Verify", "Game preparation is incomplete.")
        }
        let originalBytes = try verificationBytes(payload)
        let mutationSizes = try staging.mutations.map { mutation in
            let path = try SteamPlanBuilder.relativePath(mutation.relativePath)
            return Int64(try directory.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        let total = try mutationSizes.reduce(originalBytes) { sum, size in
            let result = sum.addingReportingOverflow(size)
            guard !result.overflow else { throw SteamPlanBuilder.failure("Verify", "The verification size is too large.") }
            return result.partialValue
        }
        let verification = try await verifyOriginals(plan, at: directory, staging: staging) { check in
            progress(.init(file: check.file, bytesChecked: check.bytesChecked, bytesTotal: total, scope: .installation))
        }
        guard verification.isValid else { throw SteamPlanBuilder.failure("Verify", "Some game files are missing or damaged. Verify files to repair them.") }
        var completed = originalBytes
        for (index, mutation) in staging.mutations.enumerated() {
            let path = try SteamPlanBuilder.relativePath(mutation.relativePath)
            guard try digest(directory.appendingPathComponent(path), progress: { checked in
                progress(.init(file: path, bytesChecked: completed + min(checked, mutationSizes[index]), bytesTotal: total, scope: .installation))
            }) == mutation.stagedSHA256 else { throw SteamPlanBuilder.failure("Verify", "A prepared game file changed unexpectedly.") }
            completed += mutationSizes[index]
            if executables.contains(path) {
                let original = try PEInspector.inspect(directory.appendingPathComponent(mutation.originalRelativePath))
                let prepared = try PEInspector.inspect(directory.appendingPathComponent(path))
                guard original.requiresSteamStubRuntime, prepared.architecture == original.architecture,
                      prepared.entryPointSection != nil, !prepared.requiresSteamStubRuntime else {
                    throw SteamPlanBuilder.failure("Verify", "The prepared executable does not match its original.")
                }
            }
        }
        for path in executables {
            guard try !PEInspector.inspect(directory.appendingPathComponent(path)).requiresSteamStubRuntime else {
                throw SteamPlanBuilder.failure("Verify", "A game executable still requires preparation. Retry installation.")
            }
        }
        let executable = directory.appendingPathComponent(try SteamPlanBuilder.relativePath(plan.launchSpec.executableRelativePath))
        guard try !PEInspector.inspect(executable).requiresSteamStubRuntime else {
            throw SteamPlanBuilder.failure("Verify", "The game executable still requires SteamStub unpacking.")
        }
        var spec = plan.launchSpec; spec.dllOverrides = staging.dllOverrides
        return spec
    }
    public func applyRuntimeOptions(_ options: [String: String], plan: InstallPlan, at directory: URL) async throws {
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        let apis = try apiPaths(payload)
        guard !apis.isEmpty else { return }
        let overlayOn = options["steam.overlay"] == "1"
        if payload.platform == .macOS {
            let root = directory.appendingPathComponent(Self.macSettingsRoot), settings = root.appendingPathComponent("steam_settings")
            guard FileManager.default.fileExists(atPath: settings.path) else { return }
            let ini = settings.appendingPathComponent("configs.overlay.ini")
            try rejectAPILinks(apiParent: root, settings: settings, ini: ini)
            if overlayValue(at: ini) != String(overlayOn ? 1 : 0) {
                try SteamSettingsINI.write("[overlay::general]\nenable_experimental_overlay=\(overlayOn ? 1 : 0)\n", to: ini)
            }
            return
        }
        for path in apis {
            let backup = directory.appendingPathComponent(path + ".orig")
            guard FileManager.default.fileExists(atPath: backup.path) else { continue }
            let apiParent = directory.appendingPathComponent(path).deletingLastPathComponent()
            let settings = apiParent.appendingPathComponent("steam_settings")
            let ini = settings.appendingPathComponent("configs.overlay.ini")
            try rejectAPILinks(apiParent: apiParent, settings: settings, ini: ini)
            guard overlayValue(at: ini) != String(overlayOn ? 1 : 0) else { continue }
            try SteamSettingsINI.write("[overlay::general]\nenable_experimental_overlay=\(overlayOn ? 1 : 0)\n", to: ini)
        }
    }
    public func uninstall(_ plan: InstallPlan, at directory: URL) async throws {
        _ = try SteamPlanBuilder.payload(plan, for: gameID)
        try Task.checkCancellation()
        // Steam has no separate source-side uninstall operation; the owned directory is removed by
        // Installs only after save retention, and the app's cached plan is deleted transactionally.
    }
    private func verificationBytes(_ payload: SteamInstallPayload) throws -> Int64 {
        try payload.manifests.reduce(Int64(0)) { sum, manifest in
            try ResumableDepotDownload.validateManifest(manifest)
            return try manifest.files.filter { !$0.isDirectory && !$0.isSymlink }.reduce(sum) { sum, file in
                let next = sum.addingReportingOverflow(Int64(file.size))
                guard !next.overflow else { throw SteamPlanBuilder.failure("Verify", "The verification size is too large.") }
                return next.partialValue
            }
        }
    }
    private func digest(_ url: URL, progress: (Int64) -> Void = { _ in }) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), checked: Int64 = 0
        var lastReport = ContinuousClock.now
        progress(0)
        while true {
            try Task.checkCancellation()
            guard let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty else { break }
            hash.update(data: bytes); checked += Int64(bytes.count)
            if lastReport.duration(to: .now) >= .milliseconds(250) { progress(checked); lastReport = .now }
        }
        progress(checked)
        return Data(hash.finalize())
    }
    private func apiPaths(_ payload: SteamInstallPayload) throws -> [String] {
        let names: Set<String> = payload.platform == .macOS ? ["libsteam_api.dylib"] : ["steam_api.dll", "steam_api64.dll"]
        return try payload.manifests.flatMap(\.files).filter { !$0.isDirectory && !$0.isSymlink }.map {
            try SteamPlanBuilder.relativePath($0.path)
        }.filter { names.contains(($0 as NSString).lastPathComponent.lowercased()) }.sorted()
    }
    private func replacements(_ staging: InstallStaging, payload: SteamInstallPayload) throws -> [String: String] {
        if payload.platform == .macOS { return try macReplacements(staging, payload: payload) }
        let apis = Set(try apiPaths(payload))
        let allowed = staging.version == 2 ? apis.union(try executablePaths(payload)) : apis
        let manifestPaths = Set(try payload.manifests.flatMap(\.files).map { try SteamPlanBuilder.relativePath($0.path).lowercased() })
        var result: [String: String] = [:]
        guard [1, 2].contains(staging.version) else { throw SteamPlanBuilder.failure("Verify", "Unsupported preparation receipt version.") }
        for mutation in staging.mutations {
            guard allowed.contains(mutation.relativePath), mutation.originalRelativePath == mutation.relativePath + ".orig",
                  !manifestPaths.contains(mutation.originalRelativePath.lowercased()), mutation.stagedSHA256.count == 32,
                  result.updateValue(mutation.originalRelativePath, forKey: mutation.relativePath) == nil else {
                throw SteamPlanBuilder.failure("Verify", "The preparation receipt contains an invalid original-file mapping.")
            }
        }
        let expected = Set(staging.mutations.filter { apis.contains($0.relativePath) }.map { ($0.relativePath as NSString).lastPathComponent.lowercased().replacingOccurrences(of: ".dll", with: "=n,b") })
        guard staging.dllOverrides.isEmpty || Set(staging.dllOverrides) == expected else {
            throw SteamPlanBuilder.failure("Verify", "The preparation receipt contains unexpected runtime overrides.")
        }
        return result
    }
    private func executablePaths(_ payload: SteamInstallPayload) throws -> [String] {
        try payload.manifests.flatMap(\.files).filter { !$0.isDirectory && !$0.isSymlink && $0.path.lowercased().hasSuffix(".exe") }
            .map { try SteamPlanBuilder.relativePath($0.path) }.sorted()
    }
    /// Unlike `rejectLinks`, avoids a full recursive scan of the installation: it only checks the
    /// handful of paths `applyRuntimeOptions` is about to write through or below.
    private func rejectAPILinks(apiParent: URL, settings: URL, ini: URL) throws {
        for url in [apiParent, settings] {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw SteamPlanBuilder.failure("Prepare", "This game uses linked files that need a preparation recipe.")
            }
        }
        guard FileManager.default.fileExists(atPath: ini.path) else { return }
        if try ini.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw SteamPlanBuilder.failure("Prepare", "This game uses linked files that need a preparation recipe.")
        }
    }
    /// The current `enable_experimental_overlay` value under `[overlay::general]`, if the ini
    /// exists and already has one, so `applyRuntimeOptions` can skip an unnecessary rewrite.
    private func overlayValue(at ini: URL) -> String? {
        guard let original = try? Data(contentsOf: ini) else { return nil }
        let bom = Data([0xEF, 0xBB, 0xBF])
        guard let text = String(data: original.starts(with: bom) ? original.dropFirst(3) : original, encoding: .utf8) else { return nil }
        var inSection = false
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inSection = trimmed.lowercased() == "[overlay::general]"; continue }
            guard inSection, !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "enable_experimental_overlay" else { continue }
            return trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
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

private final class PreparationReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private let callback: @Sendable (InstallPreparationProgress) -> Void
    init(_ callback: @escaping @Sendable (InstallPreparationProgress) -> Void) { self.callback = callback }
    func report(_ step: InstallPreparationProgress.Step) {
        lock.withLock { sequence += 1; callback(.init(step: step, sequence: sequence)) }
    }
}

// MARK: - Mac builds

/// Re-signs app bundles after their Steam API library is replaced.
protocol CodeSigning: Sendable {
    func sign(_ bundle: URL) async throws
    func verify(_ bundle: URL) async throws
}
/// An ad-hoc signature without the hardened runtime, so the bundle may load gbe_fork. Only the
/// bundle itself is signed: nested frameworks keep their original, still valid signatures.
struct AdHocCodeSigner: CodeSigning {
    func sign(_ bundle: URL) async throws { try await run(["--force", "--sign", "-", bundle.path], stage: "Prepare") }
    func verify(_ bundle: URL) async throws { try await run(["--verify", bundle.path], stage: "Verify") }
    private func run(_ arguments: [String], stage: String) async throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw OperationFailure(stage: stage, reason: "macOS couldn’t sign the prepared game. Its original files are kept.", output: text)
        }
    }
}

extension SteamInstaller {
    /// Originals of replaced or re-signed files. Outside every app bundle, which must not contain
    /// unsigned code, and inside the owned game folder, so Verify files can check them.
    static let macOriginals = ".playden-originals"
    /// Where `GseAppPath` points: its `steam_settings` can change without touching a signed bundle.
    static let macSettingsRoot = ".playden-steam"

    /// Enclosing app bundles of the Steam API libraries, relative to the game folder.
    private func macBundles(_ apis: [String]) -> [String] {
        Array(Set(apis.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            guard let index = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
            return parts[...index].joined(separator: "/")
        })).sorted()
    }
    /// Bundles that shipped with a code signature. Unsigned ones (older Intel builds such as
    /// DEMON'S TILT) stay unsigned: `codesign` refuses them for their unsigned nested libraries.
    private func signedMacBundles(_ payload: SteamInstallPayload) throws -> [String] {
        let files = Set(try payload.manifests.flatMap(\.files).filter { !$0.isDirectory }.map { try SteamPlanBuilder.relativePath($0.path) })
        return macBundles(try apiPaths(payload)).filter { files.contains($0 + "/Contents/_CodeSignature/CodeResources") }
    }
    /// Files that ad-hoc signing a bundle rewrites: its executables and its resource seal.
    private func macSignedFiles(_ payload: SteamInstallPayload) throws -> [String] {
        let bundles = try signedMacBundles(payload)
        return try payload.manifests.flatMap(\.files).filter { !$0.isDirectory && !$0.isSymlink }.map { try SteamPlanBuilder.relativePath($0.path) }.filter { path in
            bundles.contains { bundle in
                let macOS = bundle + "/Contents/MacOS/"
                return (path.hasPrefix(macOS) && !path.dropFirst(macOS.count).contains("/")) || path == bundle + "/Contents/_CodeSignature/CodeResources"
            }
        }.sorted()
    }
    fileprivate func macReplacements(_ staging: InstallStaging, payload: SteamInstallPayload) throws -> [String: String] {
        guard staging.mutations.isEmpty || staging.version == 3, staging.dllOverrides.isEmpty else {
            throw SteamPlanBuilder.failure("Verify", "Unsupported preparation receipt version.")
        }
        let allowed = Set(try apiPaths(payload) + macSignedFiles(payload))
        var result: [String: String] = [:]
        for mutation in staging.mutations {
            guard allowed.contains(mutation.relativePath), mutation.originalRelativePath == Self.macOriginals + "/" + mutation.relativePath,
                  mutation.stagedSHA256.count == 32, result.updateValue(mutation.originalRelativePath, forKey: mutation.relativePath) == nil else {
                throw SteamPlanBuilder.failure("Verify", "The preparation receipt contains an invalid original-file mapping.")
            }
        }
        return result
    }
    fileprivate func prepareMac(_ plan: InstallPlan, payload: SteamInstallPayload, at directory: URL,
                                reporter: PreparationReporter) async throws -> InstallStaging {
        try rejectEscapingLinks(in: directory)
        let apis = try apiPaths(payload), signed = try macSignedFiles(payload)
        let originals = directory.appendingPathComponent(Self.macOriginals)
        // Originals from an interrupted pass are usable only if they still verify.
        let recovered = InstallStaging(mutations: (apis + signed).filter { FileManager.default.fileExists(atPath: originals.appendingPathComponent($0).path) }.map {
            FileMutation(relativePath: $0, originalRelativePath: Self.macOriginals + "/" + $0, stagedSHA256: Data(repeating: 0, count: 32))
        }, version: 3)
        guard try await verifyOriginals(plan, at: directory, staging: recovered, progress: { reporter.report(.verifying($0)) }).isValid else {
            throw SteamPlanBuilder.failure("Prepare", "Original game files must be repaired before preparation can continue.")
        }
        try applyExecutableModes(payload, at: directory)
        guard !apis.isEmpty else { return InstallStaging(version: 1) }
        reporter.report(.applyingSettings)
        let settingsRoot = directory.appendingPathComponent(Self.macSettingsRoot)
        let metadata = PrepareMetadata(installDir: payload.app.installDir, installedDepotIDs: payload.manifests.map(\.depotID),
            dlcAppIDs: payload.ownedDLC, forceDLC: false, ufs: payload.app.ufs)
        let prepared = try SteamPreparer(assets: GBEAssets.bundled()).prepareMac(appID: payload.app.appID, gameDirectory: directory, originals: originals,
            settingsRoot: settingsRoot, account: PrepareAccount(accountName: "Playden", steamID: 0), metadata: metadata,
            asset: MacGBEAsset.bundled(), savePath: emulatorSaves.appendingPathComponent(String(payload.app.appID)), offline: true)
        // Offline play: GBE's LAN discovery would otherwise ask for local network access.
        try SteamSettingsINI.write("[main::connectivity]\ndisable_lan_only=0\noffline=1\ndisable_networking=1\n",
                                   to: settingsRoot.appendingPathComponent("steam_settings/configs.main.ini"))
        let root = directory.resolvingSymlinksInPath().path + "/"
        var mutations: [FileMutation] = []
        for library in prepared {
            let path = library.library.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { throw SteamPlanBuilder.failure("Prepare", "A prepared file leaves the installation folder.") }
            let relative = String(path.dropFirst(root.count))
            mutations.append(FileMutation(relativePath: relative, originalRelativePath: Self.macOriginals + "/" + relative, stagedSHA256: try digest(library.library)))
        }
        for bundle in try signedMacBundles(payload) {
            let files = signed.filter { $0.hasPrefix(bundle + "/") }
            for file in files where !FileManager.default.fileExists(atPath: originals.appendingPathComponent(file).path) {
                let backup = originals.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: directory.appendingPathComponent(file), to: backup)
            }
            try await codeSigner.sign(directory.appendingPathComponent(bundle))
            for file in files {
                mutations.append(FileMutation(relativePath: file, originalRelativePath: Self.macOriginals + "/" + file, stagedSHA256: try digest(directory.appendingPathComponent(file))))
            }
        }
        return InstallStaging(mutations: mutations.sorted { $0.relativePath < $1.relativePath }, version: 3)
    }
    fileprivate func validateMac(_ plan: InstallPlan, payload: SteamInstallPayload, at directory: URL, staging: InstallStaging,
                                 progress: @escaping @Sendable (InstallFileVerification) -> Void) async throws -> LaunchSpec {
        try rejectEscapingLinks(in: directory)
        let apis = Set(try apiPaths(payload)), changed = Set(staging.mutations.map(\.relativePath))
        guard apis.isSubset(of: changed), changed.isSubset(of: apis.union(try macSignedFiles(payload))) else {
            throw SteamPlanBuilder.failure("Verify", "Game preparation is incomplete.")
        }
        guard try await verifyOriginals(plan, at: directory, staging: staging, progress: progress).isValid else {
            throw SteamPlanBuilder.failure("Verify", "Some game files are missing or damaged. Verify files to repair them.")
        }
        for mutation in staging.mutations {
            guard try digest(directory.appendingPathComponent(mutation.relativePath)) == mutation.stagedSHA256 else {
                throw SteamPlanBuilder.failure("Verify", "A prepared game file changed unexpectedly.")
            }
        }
        let bundle = directory.appendingPathComponent(try SteamPlanBuilder.relativePath(plan.launchSpec.executableRelativePath))
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let executable = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/" + executable).path) else {
            throw SteamPlanBuilder.failure("Verify", "The Mac app is missing or can’t be opened. Verify files to repair it.")
        }
        for signed in try signedMacBundles(payload) { try await codeSigner.verify(directory.appendingPathComponent(signed)) }
        var spec = plan.launchSpec
        if !apis.isEmpty { spec.environment["GseAppPath"] = LaunchSpec.gameDirectoryToken + Self.macSettingsRoot }
        return spec
    }
    /// Depot downloads are written owner-read/write only; apps need their executables runnable.
    private func applyExecutableModes(_ payload: SteamInstallPayload, at directory: URL) throws {
        for file in payload.manifests.flatMap(\.files) where !file.isDirectory && !file.isSymlink {
            let path = try SteamPlanBuilder.relativePath(file.path)
            guard file.isExecutable || path.contains("/Contents/MacOS/") else { continue }
            let url = directory.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
    private func checkLinks(in directory: URL, payload: SteamInstallPayload) throws {
        if payload.platform == .macOS { try rejectEscapingLinks(in: directory) } else { try rejectLinks(in: directory) }
    }
    /// Mac bundles rely on framework symlinks. Links are allowed only when they stay in the folder.
    private func rejectEscapingLinks(in directory: URL) throws {
        let root = directory.resolvingSymlinksInPath().path
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw SteamPlanBuilder.failure("Prepare", "The game directory is unavailable.")
        }
        for case let file as URL in files {
            try Task.checkCancellation()
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else { continue }
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
            let resolved = target.hasPrefix("/") ? URL(fileURLWithPath: target) : file.deletingLastPathComponent().appendingPathComponent(target)
            let path = resolved.standardizedFileURL.resolvingSymlinksInPath().path
            guard path == root || path.hasPrefix(root + "/") else {
                throw SteamPlanBuilder.failure("Prepare", "This game links to files outside its folder.")
            }
        }
    }
}
