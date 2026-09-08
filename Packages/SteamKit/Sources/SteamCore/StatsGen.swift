import Foundation

// Swift lift of Android statsgen/* at the surveyed GameNative commit
// d8535825398afb1446d63f95ba53698cf1586847. Source file commits:
// Models.kt d580e94e, StatsAchievementsGenerator.kt 7ce410df,
// VdfParser.kt d580e94e.

public struct GeneratedAchievement: Sendable {
    public let name: String
    public let unlocked: Bool?
    public let unlockTimestamp: UInt32?
}

public struct GeneratedStat: Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let defaultValue: String
    public let globalValue: String
    public let minimum: String?
}

public struct AchievementBitLocation: Codable, Equatable, Sendable {
    public let block: Int
    public let bit: Int
}

public struct StatsGenerationResult: Sendable {
    public let achievements: [GeneratedAchievement]
    public let stats: [GeneratedStat]
    public let nameToBlockBit: [String: AchievementBitLocation]
}

public enum StatsAchievementsGenerator {
    public static func generate(schema: Data, userStats: SteamUserStatsData? = nil,
                                configDirectory: URL) throws -> StatsGenerationResult {
        let parsed = try BinaryVDFParser.parse(schema)
        var achievements: [AchievementModel] = []
        var stats: [GeneratedStat] = []
        var mapping: [String: AchievementBitLocation] = [:]

        for (_, appValue) in parsed.sorted(by: { numericKeyOrder($0.key, $1.key) }) {
            guard let app = appValue as? [String: Any],
                  let statInfo = app["stats"] as? [String: Any] else { continue }
            for (statKey, statValue) in statInfo.sorted(by: { numericKeyOrder($0.key, $1.key) }) {
                guard let stat = statValue as? [String: Any], let rawType = stat["type"] else { continue }
                let statType = stringify(rawType)
                if statType == "4" || statType == "ACHIEVEMENTS" {
                    guard let bits = stat["bits"] as? [String: Any] else { continue }
                    for (bitKey, bitValue) in bits.sorted(by: { numericKeyOrder($0.key, $1.key) }) {
                        guard let achievement = bitValue as? [String: Any] else { continue }
                        let display = achievement["display"] as? [String: Any] ?? [:]
                        var displayName: [String: String]?
                        var description: [String: String]?
                        var hidden = 0
                        var icon: String?
                        var iconGray: String?
                        var iconGrayAlternate: String?

                        for (key, value) in display {
                            switch key.lowercased() {
                            case "name": displayName = languageMap(value)
                            case "desc": description = languageMap(value)
                            case "hidden": hidden = intValue(value) ?? 0
                            case "icon": icon = stringify(value)
                            case "icon_gray": iconGray = stringify(value)
                            case "icongray": iconGrayAlternate = stringify(value)
                            default: break
                            }
                        }
                        let name = achievement["name"].map(stringify) ?? ""
                        if !name.isEmpty, let block = Int(statKey), let bit = Int(bitKey) {
                            mapping[name] = AchievementBitLocation(block: block, bit: bit)
                        }
                        achievements.append(AchievementModel(
                            name: name, displayName: displayName, description: description,
                            hidden: hidden, icon: icon, iconGray: iconGray,
                            iconGrayAlternate: iconGrayAlternate))
                    }
                } else {
                    let type: String
                    switch statType {
                    case "2", "FLOAT": type = "float"
                    case "3", "AVGRATE": type = "avgrate"
                    default: type = "int"
                    }
                    stats.append(GeneratedStat(
                        id: statKey,
                        name: stat["name"].map(stringify) ?? "",
                        type: type,
                        defaultValue: (stat["Default"] ?? stat["default"]).map(stringify) ?? "0",
                        globalValue: "0",
                        minimum: stat["min"].map(stringify)))
                }
            }
        }

        let unlocks = expandedUnlocks(userStats: userStats, mapping: mapping)
        let generatedAchievements = achievements.map { achievement in
            let timestamp = unlocks[achievement.name]
            if let timestamp, timestamp > 0 {
                return GeneratedAchievement(name: achievement.name, unlocked: true,
                                            unlockTimestamp: timestamp)
            }
            return GeneratedAchievement(name: achievement.name, unlocked: nil, unlockTimestamp: nil)
        }

        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let achievementOutput = achievements.map {
            AchievementOutput(hidden: $0.hidden,
                              displayName: $0.displayName ?? [:],
                              description: $0.description ?? [:],
                              icon: "img/\(($0.icon?.isEmpty == false) ? $0.icon! : "steam_default_icon_unlocked.jpg")",
                              iconGray: "img/\(($0.iconGray?.isEmpty == false) ? $0.iconGray! : "steam_default_icon_locked.jpg")",
                              name: $0.name, earned: false, earnTime: 0)
        }
        try writeJSON(achievementOutput, to: configDirectory.appendingPathComponent("achievements.json"))

        if !stats.isEmpty {
            let statOutput = try stats.map { stat -> StatOutput in
                let defaultValue: String
                let globalValue: String
                if stat.type == "int" {
                    if let value = Int(stat.defaultValue) {
                        defaultValue = String(value)
                    } else if let value = Float(stat.defaultValue) {
                        defaultValue = String(Int(value))
                    } else if let minimum = stat.minimum, let value = Int(minimum) {
                        defaultValue = String(value)
                    } else {
                        throw SteamError.prepare("stat \(stat.id) has no usable default or minimum")
                    }
                    globalValue = "0"
                } else {
                    guard let value = Float(stat.defaultValue) else {
                        throw SteamError.prepare("stat \(stat.id) has an invalid floating default")
                    }
                    defaultValue = String(value)
                    globalValue = "0.0"
                }
                return StatOutput(id: stat.id, defaultValue: defaultValue, globalValue: globalValue,
                                  name: stat.name, type: stat.type)
            }
            try writeJSON(statOutput, to: configDirectory.appendingPathComponent("stats.json"))
        }
        if !mapping.isEmpty {
            let output = Dictionary(uniqueKeysWithValues: mapping.map { ($0.key, [$0.value.block, $0.value.bit]) })
            try writeJSON(output, to: configDirectory.appendingPathComponent("achievement_name_to_block.json"))
        }

        return StatsGenerationResult(achievements: generatedAchievements, stats: stats,
                                     nameToBlockBit: mapping)
    }

    private struct AchievementModel {
        let name: String
        let displayName: [String: String]?
        let description: [String: String]?
        let hidden: Int
        let icon: String?
        let iconGray: String?
        let iconGrayAlternate: String?
    }

    private struct AchievementOutput: Codable {
        let hidden: Int
        let displayName: [String: String]
        let description: [String: String]
        let icon: String
        let iconGray: String
        let name: String
        let earned: Bool
        let earnTime: Int

        enum CodingKeys: String, CodingKey {
            case hidden, displayName, description, icon, name, earned
            case iconGray = "icon_gray"
            case earnTime = "earn_time"
        }
    }

    private struct StatOutput: Codable {
        let id: String
        let defaultValue: String
        let globalValue: String
        let name: String
        let type: String

        enum CodingKeys: String, CodingKey {
            case id, name, type
            case defaultValue = "default"
            case globalValue = "global"
        }
    }

    private static func expandedUnlocks(userStats: SteamUserStatsData?,
                                        mapping: [String: AchievementBitLocation]) -> [String: UInt32] {
        guard let userStats else { return [:] }
        let blocks = Dictionary(uniqueKeysWithValues: userStats.achievementBlocks.map { (Int($0.id), $0.unlockTimes) })
        var result: [String: UInt32] = [:]
        for (name, location) in mapping {
            if let times = blocks[location.block], location.bit >= 0, location.bit < times.count {
                result[name] = times[location.bit]
            }
        }
        return result
    }

    private static func languageMap(_ value: Any) -> [String: String] {
        if let values = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: values.map { ($0.key, stringify($0.value)) })
        }
        return ["english": stringify(value)]
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let value as String: return value
        case let value as Int32: return String(value)
        case let value as Int64: return String(value)
        case let value as UInt64: return String(value)
        case let value as Float: return String(value)
        default: return String(describing: value)
        }
    }

    private static func intValue(_ value: Any) -> Int? { Int(stringify(value)) }

    private static func numericKeyOrder(_ lhs: String, _ rhs: String) -> Bool {
        if let left = Int(lhs), let right = Int(rhs) { return left < right }
        return lhs < rhs
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private enum BinaryVDFParser {
    static func parse(_ data: Data) throws -> [String: Any] {
        var reader = Reader(data: data)
        return try reader.section()
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func section() throws -> [String: Any] {
            var result: [String: Any] = [:]
            while offset < data.count {
                let type = try byte()
                if type == 0x08 { break }
                let key = try string()
                switch type {
                case 0x00: result[key] = try section()
                case 0x01: result[key] = try string()
                case 0x02: result[key] = Int32(bitPattern: try uint32())
                case 0x03: result[key] = Float(bitPattern: try uint32())
                case 0x07: result[key] = Int64(bitPattern: try uint64())
                case 0x0a: result[key] = try uint64()
                default: throw SteamError.prepare(String(format: "unsupported binary VDF type 0x%02x", type))
                }
            }
            return result
        }

        mutating func byte() throws -> UInt8 {
            guard offset < data.count else { throw SteamError.prepare("truncated binary VDF") }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func string() throws -> String {
            let start = offset
            while offset < data.count, data[offset] != 0 { offset += 1 }
            guard offset < data.count else { throw SteamError.prepare("unterminated binary VDF string") }
            let string = String(data: data[start..<offset], encoding: .utf8)
            offset += 1
            guard let string else { throw SteamError.prepare("invalid UTF-8 in binary VDF") }
            return string
        }

        mutating func uint32() throws -> UInt32 {
            guard offset + 4 <= data.count else { throw SteamError.prepare("truncated binary VDF uint32") }
            defer { offset += 4 }
            return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }

        mutating func uint64() throws -> UInt64 {
            guard offset + 8 <= data.count else { throw SteamError.prepare("truncated binary VDF uint64") }
            var value: UInt64 = 0
            for index in 0..<8 { value |= UInt64(data[offset + index]) << UInt64(index * 8) }
            offset += 8
            return value
        }
    }
}
