import Foundation

public struct OwnedGame: Sendable {
    public let appID: UInt32
    public let name: String
    public let playtimeMinutes: Int
    public let lastPlayedAt: Date?
    public init(appID: UInt32, name: String, playtimeMinutes: Int, lastPlayedAt: Date? = nil) {
        self.appID = appID; self.name = name; self.playtimeMinutes = playtimeMinutes; self.lastPlayedAt = lastPlayedAt
    }
}

public enum SteamLibrary {
    /// Owned games via IPlayerService/GetOwnedGames (JSON, needs the access token).
    public static func ownedGames(steamID: UInt64, accessToken: String) async throws -> [OwnedGame] {
        let json = try await SteamWebAPI.callJSON(
            interface: "IPlayerService", method: "GetOwnedGames",
            params: [
                "access_token": accessToken,
                "steamid": String(steamID),
                "include_appinfo": "true",
                "include_played_free_games": "true",
            ])
        return try parseOwnedGames(json)
    }
    static func parseOwnedGames(_ json: [String: Any]) throws -> [OwnedGame] {
        guard let response = json["response"] as? [String: Any] else {
            throw SteamError.protocolError("GetOwnedGames: no response object")
        }
        guard let games = response["games"] as? [[String: Any]] else {
            if let count = response["game_count"] as? Int, count == 0 { return [] }
            throw SteamError.protocolError("GetOwnedGames: missing games; preserving cached library")
        }
        if let count = response["game_count"] as? Int, count != games.count {
            throw SteamError.protocolError("GetOwnedGames: incomplete games response")
        }
        return try games.map { g in
            guard let appid = g["appid"] as? Int, appid > 0, let id = UInt32(exactly: appid) else {
                throw SteamError.protocolError("GetOwnedGames: invalid app ID")
            }
            let played = (g["rtime_last_played"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return OwnedGame(appID: id, name: (g["name"] as? String) ?? "app_\(appid)",
                playtimeMinutes: max(0, (g["playtime_forever"] as? Int) ?? 0), lastPlayedAt: played)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
