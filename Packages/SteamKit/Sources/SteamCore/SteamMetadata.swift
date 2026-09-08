import Foundation
import SwiftProtobuf
import SteamProto

public struct SteamStatValue: Sendable {
    public let id: UInt32
    public let value: UInt32

    public init(id: UInt32, value: UInt32) {
        self.id = id
        self.value = value
    }
}

public struct SteamAchievementBlock: Sendable {
    public let id: UInt32
    public let unlockTimes: [UInt32]

    public init(id: UInt32, unlockTimes: [UInt32]) {
        self.id = id
        self.unlockTimes = unlockTimes
    }
}

public struct SteamUserStatsData: Sendable {
    public let appID: UInt32
    public let crc: UInt32
    public let schema: Data
    public let stats: [SteamStatValue]
    public let achievementBlocks: [SteamAchievementBlock]

    public init(appID: UInt32, crc: UInt32, schema: Data, stats: [SteamStatValue],
                achievementBlocks: [SteamAchievementBlock]) {
        self.appID = appID
        self.crc = crc
        self.schema = schema
        self.stats = stats
        self.achievementBlocks = achievementBlocks
    }
}

public extension CMClient {
    /// JavaSteam's SteamApps.requestEncryptedAppTicket equivalent. The returned
    /// bytes serialize the complete EncryptedAppTicket protobuf, matching the
    /// Android value placed in configs.user.ini after base64 encoding.
    func requestEncryptedAppTicket(appID: UInt32, userData: Data = Data()) async throws -> Data {
        var request = CMsgClientRequestEncryptedAppTicket()
        request.appID = appID
        if !userData.isEmpty { request.userdata = userData }
        let parts = try await jobRequest(.kEmsgClientRequestEncryptedAppTicket, body: request)
        guard let first = parts.first else {
            throw SteamError.protocolError("encrypted app ticket: empty response")
        }
        return try Self.decodeEncryptedAppTicketResponse(first, expectedAppID: appID)
    }

    static func decodeEncryptedAppTicketResponse(_ data: Data, expectedAppID: UInt32) throws -> Data {
        let response = try CMsgClientRequestEncryptedAppTicketResponse(serializedBytes: data)
        let result = EResult(rawValue: response.eresult)
        guard result == .ok else {
            throw SteamError.eresult(result, context: "encrypted app ticket for \(expectedAppID)")
        }
        guard response.appID == expectedAppID else {
            throw SteamError.protocolError("encrypted app ticket returned app \(response.appID), expected \(expectedAppID)")
        }
        guard response.hasEncryptedAppTicket else {
            throw SteamError.protocolError("encrypted app ticket response has no ticket")
        }
        return try response.encryptedAppTicket.serializedData()
    }

    /// JavaSteam SteamUserStats.getUserStats equivalent, used by the lifted
    /// statsgen path to obtain the binary achievement/stat schema.
    func userStats(appID: UInt32, steamID: UInt64) async throws -> SteamUserStatsData {
        var request = CMsgClientGetUserStats()
        request.gameID = UInt64(appID)
        request.steamIDForUser = steamID
        let parts = try await jobRequest(.kEmsgClientGetUserStats, body: request)
        guard let first = parts.first else {
            throw SteamError.protocolError("user stats: empty response")
        }
        return try Self.decodeUserStatsResponse(first, expectedAppID: appID)
    }

    static func decodeUserStatsResponse(_ data: Data, expectedAppID: UInt32) throws -> SteamUserStatsData {
        let response = try CMsgClientGetUserStatsResponse(serializedBytes: data)
        let result = EResult(rawValue: response.eresult)
        guard result == .ok else {
            throw SteamError.eresult(result, context: "user stats for \(expectedAppID)")
        }
        guard UInt32(truncatingIfNeeded: response.gameID) == expectedAppID else {
            throw SteamError.protocolError("user stats returned app \(response.gameID), expected \(expectedAppID)")
        }
        return SteamUserStatsData(
            appID: expectedAppID,
            crc: response.crcStats,
            schema: response.schema,
            stats: response.stats.map { SteamStatValue(id: $0.statID, value: $0.statValue) },
            achievementBlocks: response.achievementBlocks.map {
                SteamAchievementBlock(id: $0.achievementID, unlockTimes: $0.unlockTime)
            })
    }
}

/// The Android layer keeps encrypted app tickets for 30 minutes. This file
/// cache supplies the same behavior without adding a database dependency.
public final class EncryptedAppTicketCache {
    private struct Entry: Codable {
        let timestamp: Date
        let protobufBase64: String
    }

    public let file: URL
    public var lifetime: TimeInterval = 30 * 60

    public init(directory: URL = TokenStore.directory) {
        file = directory.appendingPathComponent("encrypted-app-tickets.json")
    }

    public func ticket(appID: UInt32, now: Date = Date(),
                       fetch: () async throws -> Data) async throws -> Data {
        var entries = load()
        if let entry = entries[String(appID)],
           now.timeIntervalSince(entry.timestamp) >= 0,
           now.timeIntervalSince(entry.timestamp) < lifetime,
           let data = Data(base64Encoded: entry.protobufBase64) {
            return data
        }
        let data = try await fetch()
        entries[String(appID)] = Entry(timestamp: now, protobufBase64: data.base64EncodedString())
        try save(entries)
        return data
    }

    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    private func save(_ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
