import Foundation

public struct InstallEstimate: Codable, Equatable, Sendable {
    public let downloadBytes: Int64
    public let installedBytes: Int64
    /// Includes retained originals and temporary assembly space, not just final file sizes.
    public let requiredBytes: Int64
    public init(downloadBytes: Int64, installedBytes: Int64, requiredBytes: Int64) {
        self.downloadBytes = downloadBytes; self.installedBytes = installedBytes; self.requiredBytes = requiredBytes
    }
}
/// Immutable resolution shared by confirmation, job recovery and later repair.
/// sourcePayload is versioned source metadata, never credentials, tickets or account identifiers.
public struct InstallPlan: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let game: SourceGameRecord
    public let language: String
    public let manifestIDs: [String: String]
    public let estimate: InstallEstimate
    public let launchSpec: LaunchSpec
    public let launchOptions: [LaunchOption]?
    public let sourcePayload: Data
    public let recipeVersion: Int
    public let resolvedAt: Date
    public init(id: UUID = UUID(), game: SourceGameRecord, language: String = "english", manifestIDs: [String: String],
                estimate: InstallEstimate, launchSpec: LaunchSpec, sourcePayload: Data, recipeVersion: Int = 1, resolvedAt: Date = .now,
                launchOptions: [LaunchOption]? = nil) {
        self.id = id; self.game = game; self.language = language; self.manifestIDs = manifestIDs
        self.estimate = estimate; self.launchSpec = launchSpec; self.sourcePayload = sourcePayload
        self.recipeVersion = recipeVersion; self.resolvedAt = resolvedAt
        self.launchOptions = launchOptions
    }
}
/// Ephemeral disk-check progress; never counted as downloaded or written bytes.
public struct InstallFileVerification: Equatable, Sendable {
    public enum Scope: Sendable { case file, installation }
    public let scope: Scope
    public let file: String
    public let bytesChecked: Int64
    public let bytesTotal: Int64
    public init(file: String, bytesChecked: Int64, bytesTotal: Int64, scope: Scope = .file) {
        self.scope = scope; self.file = file; self.bytesChecked = bytesChecked; self.bytesTotal = bytesTotal
    }
    public var fraction: Double { bytesTotal > 0 ? min(1, max(0, Double(bytesChecked) / Double(bytesTotal))) : 0 }
}
public struct InstallPreparationProgress: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case verifying(InstallFileVerification)
        case preparingExecutable(String)
        case applyingSettings
    }
    public let step: Step
    public let sequence: UInt64
    public init(step: Step, sequence: UInt64) { self.step = step; self.sequence = sequence }
}

public struct InstallProgress: Equatable, Sendable {
    public let bytesCompleted: Int64
    public let bytesTotal: Int64
    public let currentFile: String
    /// Invocation-local counters; never restored from a durable job's assembled byte count.
    public let downloadedBytes: Int64?
    public let freshlyWrittenBytes: Int64?
    public let verification: InstallFileVerification?
    /// Invocation-local ordering for concurrent callback delivery.
    public let sequence: UInt64?
    public init(bytesCompleted: Int64, bytesTotal: Int64, currentFile: String, downloadedBytes: Int64? = nil, freshlyWrittenBytes: Int64? = nil, verification: InstallFileVerification? = nil, sequence: UInt64? = nil) {
        self.bytesCompleted = bytesCompleted; self.bytesTotal = bytesTotal; self.currentFile = currentFile
        self.downloadedBytes = downloadedBytes; self.freshlyWrittenBytes = freshlyWrittenBytes; self.verification = verification; self.sequence = sequence
    }
}
public struct FileMutation: Codable, Equatable, Sendable {
    public let relativePath: String
    public let originalRelativePath: String
    public let stagedSHA256: Data
    public init(relativePath: String, originalRelativePath: String, stagedSHA256: Data) {
        self.relativePath = relativePath; self.originalRelativePath = originalRelativePath; self.stagedSHA256 = stagedSHA256
    }
}
public struct InstallStaging: Codable, Equatable, Sendable {
    public var mutations: [FileMutation]
    public var dllOverrides: [String]
    public var version: Int
    public init(mutations: [FileMutation] = [], dllOverrides: [String] = [], version: Int = 1) {
        self.mutations = mutations; self.dllOverrides = dllOverrides; self.version = version
    }
}
public struct VerificationResult: Equatable, Sendable {
    public let invalidFiles: [String]
    public var isValid: Bool { invalidFiles.isEmpty }
    public init(invalidFiles: [String] = []) { self.invalidFiles = invalidFiles }
}
/// Task cancellation pauses work at a durable boundary. The orchestrator owns queue state,
/// filesystem reservation/deletion, bottles, save retention and the final Catalog transaction.
public protocol Installer: Sendable {
    var gameID: GameID { get }
    func resolve() async throws -> InstallPlan
    func launchOptions(_ plan: InstallPlan) throws -> [LaunchOption]
    func download(_ plan: InstallPlan, to directory: URL,
                  progress: @escaping @Sendable (InstallProgress) -> Void) async throws
    func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?) async throws -> VerificationResult
    func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?,
        progress: @escaping @Sendable (InstallFileVerification) -> Void) async throws -> VerificationResult
    func repair(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?,
                progress: @escaping @Sendable (InstallProgress) -> Void) async throws
    func postInstall(_ plan: InstallPlan, at directory: URL) async throws -> InstallStaging
    func preparePrerequisites(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle) async throws
    func postInstall(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle) async throws -> InstallStaging
    func postInstall(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle,
        progress: @escaping @Sendable (InstallPreparationProgress) -> Void) async throws -> InstallStaging
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging) async throws -> LaunchSpec
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging,
        progress: @escaping @Sendable (InstallFileVerification) -> Void) async throws -> LaunchSpec
    func saveMapping(_ plan: InstallPlan) throws -> SaveMapping
    /// Source-specific per-game options resolved from the runtime profile, applied before every launch.
    func applyRuntimeOptions(_ options: [String: String], plan: InstallPlan, at directory: URL) async throws
    /// Source-side cleanup only. Removing the owned game directory/bottle is the orchestrator's job.
    func uninstall(_ plan: InstallPlan, at directory: URL) async throws
}
public extension Installer {
    func postInstall(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle,
        progress: @escaping @Sendable (InstallPreparationProgress) -> Void) async throws -> InstallStaging {
        try await postInstall(plan, at: directory, in: bottle)
    }
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging,
        progress: @escaping @Sendable (InstallFileVerification) -> Void) async throws -> LaunchSpec {
        try await validate(plan, at: directory, staging: staging)
    }
    func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?,
        progress: @escaping @Sendable (InstallFileVerification) -> Void) async throws -> VerificationResult {
        try await verifyOriginals(plan, at: directory, staging: staging)
    }
    func launchOptions(_ plan: InstallPlan) throws -> [LaunchOption] { plan.launchOptions ?? [] }
    func preparePrerequisites(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle) async throws {}
    func postInstall(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle) async throws -> InstallStaging {
        try await postInstall(plan, at: directory)
    }
    func saveMapping(_ plan: InstallPlan) throws -> SaveMapping { SaveMapping() }
    func applyRuntimeOptions(_ options: [String: String], plan: InstallPlan, at directory: URL) async throws {}
    /// Unmodified sources can reuse their resumable downloader. Sources with staged originals
    /// must provide a repair implementation so backups are never replaced with modified files.
    func repair(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?,
                progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        guard staging?.mutations.isEmpty != false else {
            throw OperationFailure(stage: "Repair", reason: "This store does not support repairing prepared files yet.", output: "")
        }
        if try await !verifyOriginals(plan, at: directory, staging: staging).isValid {
            try await download(plan, to: directory, progress: progress)
        }
    }
}
