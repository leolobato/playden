import Foundation

/// A volume's stable identity is authoritative; its most recent mount path is only a hint.
public struct GameLocation: Codable, Equatable, Sendable {
    public var volumeID: String
    public var rootBookmark: Data?
    public var lastKnownRoot: URL
    public var relativePath: String
    public var relativeRoot: String?
    public init(volumeID: String, rootBookmark: Data? = nil, lastKnownRoot: URL, relativePath: String) {
        self.volumeID = volumeID; self.rootBookmark = rootBookmark; self.lastKnownRoot = lastKnownRoot; self.relativePath = relativePath
    }
}
public struct LaunchSpec: Codable, Equatable, Sendable {
    public var executableRelativePath: String
    public var workingDirectoryRelativePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var dllOverrides: [String]
    public init(executableRelativePath: String, workingDirectoryRelativePath: String = ".", arguments: [String] = [],
                environment: [String: String] = [:], dllOverrides: [String] = []) {
        self.executableRelativePath = executableRelativePath; self.workingDirectoryRelativePath = workingDirectoryRelativePath
        self.arguments = arguments; self.environment = environment; self.dllOverrides = dllOverrides
    }
}
public struct InstallationRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var gameID: GameID
    /// Retains display metadata for offline installs when the source catalog is cleared on logout.
    public var game: SourceGameRecord
    public var location: GameLocation
    public var bottleID: String
    public var ownershipToken: UUID
    public var manifestIDs: [String: String]
    public var language: String
    public var templateVersion: String
    public var recipeVersion: Int
    public var stagingVersion: Int
    public var launchSpec: LaunchSpec
    public var installedAt: Date
    public var installedBytes: Int64
    public var plan: InstallPlan?
    public var staging: InstallStaging?
    public init(id: UUID = UUID(), game: SourceGameRecord, location: GameLocation, bottleID: String,
                ownershipToken: UUID = UUID(), manifestIDs: [String: String], language: String = "english",
                templateVersion: String, recipeVersion: Int = 1, stagingVersion: Int = 1,
                launchSpec: LaunchSpec, installedAt: Date = .now, installedBytes: Int64) {
        self.id = id; self.gameID = game.id; self.game = game; self.location = location; self.bottleID = bottleID
        self.ownershipToken = ownershipToken; self.manifestIDs = manifestIDs; self.language = language
        self.templateVersion = templateVersion; self.recipeVersion = recipeVersion; self.stagingVersion = stagingVersion
        self.launchSpec = launchSpec; self.installedAt = installedAt; self.installedBytes = installedBytes
    }
}
public enum JobKind: String, Codable, Sendable { case install, repair, uninstall }
public enum JobStage: String, CaseIterable, Codable, Sendable {
    case resolve, estimate, reserve, download, verifyOriginals, createBottle, prerequisites, stage, validate, commit, preserveSaves, removeFiles, removeBottle, finished
}
public enum JobState: String, Codable, Sendable { case queued, running, stopping, paused, failed, cancelled, completed }
public enum PauseReason: String, Codable, Hashable, Sendable { case user, gameplay, authentication, unavailableDrive, insufficientSpace }
public struct JobRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var gameID: GameID
    public var kind: JobKind
    public var stage: JobStage
    public var state: JobState
    public var completedStages: Set<JobStage>
    public var pauseReasons: Set<PauseReason>
    public var queuePosition: Int
    public var manifestIDs: [String: String]
    public var location: GameLocation?
    public var ownershipToken: UUID
    public var bytesCompleted: Int64
    public var bytesTotal: Int64?
    public var createdAt: Date
    public var updatedAt: Date
    public var failure: OperationFailure?
    public var plan: InstallPlan?
    public var bottle: GameBottle?
    public var volume: GamesVolumeSelection?
    public var staging: InstallStaging?
    public var cancellationRequested: Bool?
    public var launchSpec: LaunchSpec?
    public var currentFile: String?
    public init(id: UUID = UUID(), gameID: GameID, kind: JobKind = .install, queuePosition: Int = 0, createdAt: Date = .now) {
        self.id = id; self.gameID = gameID; self.kind = kind; self.stage = .resolve; self.state = .queued
        self.completedStages = []; self.pauseReasons = []; self.queuePosition = queuePosition; self.manifestIDs = [:]
        self.location = nil; self.ownershipToken = UUID(); self.bytesCompleted = 0; self.bytesTotal = nil
        self.createdAt = createdAt; self.updatedAt = createdAt; self.failure = nil
    }
}
public enum SessionOutcome: String, Codable, Sendable { case clean, crash, forced, launchFailed, interrupted }
public struct PlaySessionRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var gameID: GameID
    public var bottleID: String
    public var startedAt: Date
    public var lastCheckpointAt: Date
    public var endedAt: Date?
    /// Accumulated from a monotonic clock, never computed from restart wall-clock gaps.
    public var playedSeconds: Int64
    public var outcome: SessionOutcome?
    public var runtime: RunSnapshot?
    public init(id: UUID = UUID(), gameID: GameID, bottleID: String, startedAt: Date = .now) {
        self.id = id; self.gameID = gameID; self.bottleID = bottleID; self.startedAt = startedAt
        self.lastCheckpointAt = startedAt; self.endedAt = nil; self.playedSeconds = 0; self.outcome = nil
    }
}
public struct OperationFailure: Codable, Equatable, Sendable, Error {
    public var stage: String
    public var reason: String
    public var timestamp: Date
    public private(set) var output: String
    public init(stage: String, reason: String, output: String, timestamp: Date = .now) {
        self.stage = stage; self.reason = DiagnosticRedactor.redact(reason); self.timestamp = timestamp
        self.output = DiagnosticRedactor.redact(output)
    }
}
public enum DiagnosticRedactor {
    public static func redact(_ text: String) -> String {
        // Redact headers, structured fields, query parameters, SteamIDs and JWTs before persistence.
        let secretKey = #"(?:refresh_?token|access_?token|password|steam_?guard|guard_?code|shared_?secret|identity_?secret|sessionid|ticket|account_?name|username|challenge_?url)"#
        let prefix = #"(?i)([\"']?"# + secretKey + #"[\"']?\s*[:=]\s*)"#
        let patterns = [
            #"(?i)(authorization\s*[:=]\s*)(?:bearer\s+)?[^\r\n]+"#,
            prefix + #"\"(?:\\.|[^\"\\])*\""#,
            prefix + #"'(?:\\.|[^'\\])*'"#,
            prefix + #"[^\s\"'&,}\r\n]+"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
            #"\b7656119[0-9]{10}\b"#,
        ]
        return patterns.enumerated().reduce(text) { result, item in
            result.replacingOccurrences(of: item.element, with: item.offset < 4 ? "$1[REDACTED]" : "[REDACTED]", options: .regularExpression)
        }
    }
}
