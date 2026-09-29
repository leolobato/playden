import Foundation
import Domain
import GOGCore

/// What a GOG install plan remembers about its build. No credentials, and no file list: the
/// resolved `GOGInstallManifest` is saved in the install folder when the download starts.
struct GOGPlanPayload: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var productID: String
    var platform: String
    var buildID: String
    var generation: Int
    var language: String
    var products: [String]
    var dependencies: [String]
    /// Mac builds whose depot root is the app bundle are written into `<bundle>/` (PRD 10 FR-GOG-26).
    var bundlePrefix: String?
}

/// Installs one GOG game: build resolution, depot download, verification and launch tasks (PRD 10 §4–§5).
struct GOGInstaller: Installer {
    let game: SourceGameRecord
    let account: GOGAccount
    var gameID: GameID { game.id }

    /// Playden's own files inside the game folder: the saved manifests and support files.
    static let dataDirectory = GOGPaths.workDirectory
    static let recipeVersion = 1

    func resolve() async throws -> InstallPlan { try await resolve(platform: .windows) }

    func resolve(platform: GamePlatform) async throws -> InstallPlan {
        let os = platform == .macOS ? "osx" : "windows"
        let productID = game.id.value
        let (resolution, info) = try await account.withSession { [api = account.api, account] session in
            let owned = Set(try await api.ownedProductIDs(accessToken: session.accessToken).map(String.init))
            guard owned.contains(productID) else { throw SourceFailure.accessDenied }
            let resolution = try await GOGResolver(api: api).resolve(productID: productID, os: os, language: GOGLanguage.english,
                                                                     owned: owned, accessToken: session.accessToken)
            guard let file = resolution.manifest.infoFile else {
                throw OperationFailure(stage: "Resolve", reason: "This GOG build has no game to start.", output: "")
            }
            let fetcher = GOGCDNFetcher(manifest: resolution.manifest, api: api) { try await account.accessToken() }
            let info = try GOGInfoFile.parse(try await GOGDownloader.contents(of: file, fetcher: fetcher))
            return (resolution, info)
        }
        var manifest = resolution.manifest
        let prefix = platform == .macOS ? Self.bundlePrefix(manifest) : nil
        if let prefix { manifest = Self.prefixed(manifest, with: prefix) }
        guard let primary = info.primaryTask, let spec = try Self.launchSpec(primary, platform: platform, prefix: prefix) else {
            throw OperationFailure(stage: "Resolve", reason: "This GOG build has no game to start.", output: "")
        }
        let options = try info.optionTasks.enumerated().compactMap { index, task -> LaunchOption? in
            guard let spec = try Self.launchSpec(task, platform: platform, prefix: prefix) else { return nil }
            let title = task.name ?? ((task.path ?? "") as NSString).lastPathComponent
            return LaunchOption(id: "gog-task-\(index)", title: title, spec: spec)
        }
        let payload = GOGPlanPayload(productID: productID, platform: os, buildID: manifest.buildID, generation: manifest.generation,
                                     language: GOGLanguage.english, products: manifest.products, dependencies: manifest.dependencies,
                                     bundlePrefix: prefix)
        let installed = manifest.installedSize
        let estimate = InstallEstimate(downloadBytes: manifest.downloadSize, installedBytes: installed, requiredBytes: installed)
        return InstallPlan(game: game, language: GOGLanguage.english, manifestIDs: ["build": manifest.buildID], estimate: estimate,
                           launchSpec: spec, sourcePayload: try JSONEncoder().encode(payload), recipeVersion: Self.recipeVersion,
                           launchOptions: options, platform: platform)
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
        let invalid = try GOGDownloader(destination: directory).invalidFiles(in: manifest) { file, checked, total in
            progress(InstallFileVerification(file: file, bytesChecked: checked, bytesTotal: total, scope: .installation))
        }
        // INI files the install script sets keys in are expected to differ from the download.
        let changed = Set(Self.installScripts(payload, at: directory).flatMap { script, context in
            script.steps(context, skipCopies: true).compactMap { step -> String? in
                guard case .setINI(let file, _, _, _, _) = step else { return nil }
                return String(file.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1)).lowercased()
            }
        })
        return VerificationResult(invalidFiles: invalid.filter { !changed.contains($0.lowercased()) })
    }

    /// Downloads again only the files that are missing or changed.
    func repair(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?,
                progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        let result = try await verifyOriginals(plan, at: directory, staging: staging)
        guard !result.isValid else { return }
        let only = result.invalidFiles.contains(Self.dataDirectory) ? nil : Set(result.invalidFiles)
        try await write(plan, to: directory, only: only, progress: progress)
    }

    /// Mac bundles need their programs runnable even where a depot omits the executable flag (FR-GOG-26).
    /// GOG breaks or omits bundle signatures, and the bundles still start, so nothing is re-signed (FR-GOG-28).
    func postInstall(_ plan: InstallPlan, at directory: URL) async throws -> InstallStaging {
        guard plan.resolvedPlatform == .macOS else {
            try Self.runInstallScripts(try Self.payload(plan), at: directory, skipCopies: false)
            return InstallStaging()
        }
        let bundle = directory.appendingPathComponent(plan.launchSpec.executableRelativePath)
        let files = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])?
            .allObjects.compactMap { $0 as? URL } ?? []
        for url in files where url.deletingLastPathComponent().lastPathComponent == "MacOS" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return InstallStaging()
    }

    /// The launch target must exist. Manifest paths ignore case, so the saved path uses the spelling on disk.
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging) async throws -> LaunchSpec {
        var spec = plan.launchSpec
        guard let target = Self.resolveCaseInsensitive(spec.executableRelativePath, in: directory, directory: plan.resolvedPlatform == .macOS) else {
            throw OperationFailure(stage: "Validate", reason: "The game's program \(spec.executableRelativePath) is missing. Verify files or reinstall.", output: "")
        }
        spec.executableRelativePath = target
        if plan.resolvedPlatform == .macOS {
            try validateBundle(directory.appendingPathComponent(target))
            return spec
        }
        if plan.resolvedPlatform == .windows, let working = Self.resolveCaseInsensitive(spec.workingDirectoryRelativePath, in: directory, directory: true) {
            spec.workingDirectoryRelativePath = working
        }
        return spec
    }

    func uninstall(_ plan: InstallPlan, at directory: URL) async throws {}

    /// GOG games need nothing per launch; the install script's INI keys are set again so paths follow a moved drive.
    func prepareLaunch(_ spec: LaunchSpec, plan: InstallPlan, at directory: URL, offline: Bool) async throws -> LaunchSpec {
        if plan.resolvedPlatform == .windows, let payload = try? Self.payload(plan) {
            try? Self.runInstallScripts(payload, at: directory, skipCopies: true)
        }
        return spec
    }

    /// Each installed product's `goggame-<id>.script` in the game folder, with its variables (PRD 10 FR-GOG-21a).
    static func installScripts(_ payload: GOGPlanPayload, at directory: URL) -> [(GOGInstallScript, GOGInstallScript.Context)] {
        guard payload.platform == "windows" else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return payload.products.compactMap { product in
            guard let name = names.first(where: { $0.lowercased() == "goggame-\(product).script" }),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let script = try? GOGInstallScript.parse(data) else { return nil }
            let context = GOGInstallScript.Context(gameRoot: directory, supportRoot: directory.appendingPathComponent(GOGPaths.support(product: product)),
                                                   productID: product, language: GOGLanguage.code(for: payload.language),
                                                   windowsAppPath: "Z:" + directory.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\"))
            return (script, context)
        }
    }

    static func runInstallScripts(_ payload: GOGPlanPayload, at directory: URL, skipCopies: Bool) throws {
        for (script, context) in installScripts(payload, at: directory) {
            do { try script.run(context, skipCopies: skipCopies) }
            catch { throw OperationFailure(stage: "Prepare", reason: "The game's setup step couldn't write its settings.", output: String(describing: error)) }
        }
    }

    /// The bundle must name a runnable program, and that program must have 64-bit code (FR-GOG-27).
    private func validateBundle(_ bundle: URL) throws {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let name = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/" + name).path) else {
            throw OperationFailure(stage: "Validate", reason: "The Mac app is missing or can’t be opened. Verify files to repair it.", output: "")
        }
        let executable = bundle.appendingPathComponent("Contents/MacOS/" + name)
        if Self.machOBitness(executable) == .only32 {
            let reason = game.availablePlatforms.contains(.windows)
                ? "This Mac version is 32-bit and can't run on this macOS. Switch to the Windows version."
                : "This Mac version is 32-bit and can't run on this macOS."
            throw OperationFailure(stage: "Validate", reason: reason, output: "")
        }
    }

    enum Bitness { case has64, only32, notMachO }

    /// Reads a Mach-O or universal header. Scripts and other files are `notMachO`.
    static func machOBitness(_ url: URL) -> Bitness {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 4096) else { return .notMachO }
        try? handle.close()
        guard head.count >= 8 else { return .notMachO }
        func u32(_ offset: Int, bigEndian: Bool) -> UInt32 {
            guard offset + 4 <= head.count else { return 0 }
            let bytes = head[head.startIndex + offset..<head.startIndex + offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return bigEndian ? bytes : bytes.byteSwapped
        }
        switch u32(0, bigEndian: true) {
        case 0xCFFA_EDFE, 0xFEED_FACF: return .has64
        case 0xCEFA_EDFE, 0xFEED_FACE: return .only32
        case 0xCAFE_BABE, 0xCAFE_BABF:
            // Universal: big-endian slice count, then 20-byte (or 32-byte for the 64-bit form) slice headers.
            let count = Int(u32(4, bigEndian: true)), stride = u32(0, bigEndian: true) == 0xCAFE_BABF ? 32 : 20
            guard count > 0, count < 32 else { return .notMachO }
            let has64 = (0..<count).contains { u32(8 + $0 * stride, bigEndian: true) & 0x0100_0000 != 0 }
            return has64 ? .has64 : .only32
        default: return .notMachO
        }
    }

    // MARK: Helpers

    /// Mac builds whose root holds `Contents/Info.plist` are the app bundle itself, so Playden
    /// writes them into `<install directory>.app`.
    static func bundlePrefix(_ manifest: GOGInstallManifest) -> String? {
        guard manifest.files.contains(where: { $0.path.lowercased() == "contents/info.plist" }) else { return nil }
        let name = manifest.installDirectory.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = name.isEmpty || name.hasPrefix(".") ? "Game" : name
        return base.lowercased().hasSuffix(".app") ? base : base + ".app"
    }

    /// Moves the game's files under `prefix`; Playden's own support folder stays at the root.
    static func prefixed(_ manifest: GOGInstallManifest, with prefix: String) -> GOGInstallManifest {
        var result = manifest
        result.files = manifest.files.map { file in
            guard !file.path.hasPrefix(dataDirectory + "/") else { return file }
            var moved = file; moved.path = prefix + "/" + file.path
            return moved
        }
        return result
    }

    /// A `FileTask` as a launch spec. Mac tasks point inside a bundle; the spec names the bundle.
    static func launchSpec(_ task: GOGInfoFile.Task, platform: GamePlatform, prefix: String?) throws -> LaunchSpec? {
        guard task.isFileTask, let raw = task.path, var path = try? GOGPaths.normalize(raw) else { return nil }
        if let prefix { path = prefix + "/" + path }
        let arguments = task.arguments.map { $0.replacingOccurrences(of: "\\", with: "/") } ?? ""
        if platform == .macOS {
            guard let bundle = enclosingBundle(path) else { return nil }
            return LaunchSpec(executableRelativePath: bundle, workingDirectoryRelativePath: ".",
                              arguments: arguments.isEmpty ? [] : try POSIXArguments.parse(arguments))
        }
        let folder = (path as NSString).deletingLastPathComponent
        var working = folder.isEmpty ? "." : folder
        if let dir = task.workingDir, !dir.isEmpty, let normalized = try? GOGPaths.normalize(dir) {
            working = (prefix.map { $0 + "/" } ?? "") + normalized
        }
        return LaunchSpec(executableRelativePath: path, workingDirectoryRelativePath: working,
                          arguments: arguments.isEmpty ? [] : try WindowsArguments.parse(task.arguments ?? ""))
    }

    /// `A.app/Contents/MacOS/A` → `A.app`: the outermost `.app` on the path.
    static func enclosingBundle(_ path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return components[...index].joined(separator: "/")
    }

    private func write(_ plan: InstallPlan, to directory: URL, only: Set<String>?, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        let payload = try Self.payload(plan)
        let manifest: GOGInstallManifest
        if let saved = try? Self.savedManifest(payload, in: directory) {
            manifest = saved
        } else {
            let resolution = try await account.withSession { [api = account.api] session in
                let owned = Set(try await api.ownedProductIDs(accessToken: session.accessToken).map(String.init))
                return try await GOGResolver(api: api).resolve(productID: payload.productID, os: payload.platform, language: payload.language,
                                                               owned: owned, accessToken: session.accessToken)
            }
            guard resolution.manifest.buildID == payload.buildID else {
                throw OperationFailure(stage: "Download", reason: "GOG has a newer version of this game. Cancel and install it again.", output: "")
            }
            let resolved = payload.bundlePrefix.map { Self.prefixed(resolution.manifest, with: $0) } ?? resolution.manifest
            try Self.save(resolved, buildManifest: resolution.buildManifest, in: directory)
            manifest = resolved
        }
        let account = self.account
        let fetcher = GOGCDNFetcher(manifest: manifest, api: account.api) { try await account.accessToken() }
        let sequence = GOGProgressSequence()
        var downloader = GOGDownloader(destination: directory)
        downloader.onProgress = { update in
            progress(InstallProgress(bytesCompleted: update.bytesDone, bytesTotal: update.bytesTotal, currentFile: update.file,
                                     downloadedBytes: update.bytesDownloaded, freshlyWrittenBytes: update.bytesWritten, sequence: sequence.next()))
        }
        do { try await downloader.download(manifest, only: only, fetcher: fetcher) }
        catch { throw GOGAccount.failure(error) }
    }

    static func payload(_ plan: InstallPlan) throws -> GOGPlanPayload {
        guard let payload = try? JSONDecoder().decode(GOGPlanPayload.self, from: plan.sourcePayload),
              payload.version == GOGPlanPayload.currentVersion else {
            throw OperationFailure(stage: "Install plan", reason: "This install plan is from another Playden version. Install the game again.", output: "")
        }
        return payload
    }

    static func save(_ manifest: GOGInstallManifest, buildManifest: Data, in directory: URL) throws {
        let folder = directory.appendingPathComponent(dataDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try buildManifest.write(to: folder.appendingPathComponent("build.json"), options: .atomic)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("install.json"), options: .atomic)
    }

    static func savedManifest(_ payload: GOGPlanPayload, in directory: URL) throws -> GOGInstallManifest {
        let url = directory.appendingPathComponent("\(dataDirectory)/install.json")
        let manifest = try JSONDecoder().decode(GOGInstallManifest.self, from: Data(contentsOf: url))
        guard manifest.buildID == payload.buildID, manifest.productID == payload.productID, manifest.platform == payload.platform else {
            throw OperationFailure(stage: "Verify", reason: "The saved GOG manifest doesn't match this install.", output: "")
        }
        return manifest
    }

    /// Finds `path` under `root`, matching each component without regard to case.
    static func resolveCaseInsensitive(_ path: String, in root: URL, directory wantsDirectory: Bool) -> String? {
        if path == "." { return "." }
        var resolved: [String] = []
        var folder = root
        for component in path.split(separator: "/").map(String.init) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                  let match = names.first(where: { $0 == component }) ?? names.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame })
            else { return nil }
            resolved.append(match); folder.appendPathComponent(match)
        }
        var isDirectory: ObjCBool = false
        guard !resolved.isEmpty, FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue == wantsDirectory else { return nil }
        return resolved.joined(separator: "/")
    }
}

private final class GOGProgressSequence: @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt64 = 0
    func next() -> UInt64 { lock.withLock { value += 1; return value } }
}
