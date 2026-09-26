import Foundation
import Domain

public struct SteamSource: GameSource {
    public let id = SourceID.steam
    public let displayName = "Steam"
    public var auth: any SourceAuth { account }
    public let capabilities = SourceCapabilities(account: .steam, acquisition: .download, cloudSaves: true)
    public let account: SteamAccount
    private let session: URLSession
    private let runtimeTools: (any RuntimeToolRunning)?
    public init(account: SteamAccount = SteamAccount(), runtimeTools: (any RuntimeToolRunning)? = nil) {
        self.account = account
        self.runtimeTools = runtimeTools
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }
    public func ownedGames() async throws -> [SourceGameRecord] { try await account.ownedGames() }
    public func storePageURL(for id: GameID) -> URL? { SteamStorePage.url(for: id) }
    public func storePageAllows(host: String) -> Bool { SteamStorePage.allows(host: host) }
    /// A Steam header is available for many older games without a portrait library cover.
    public func artworkFallbacks(for id: GameID) -> [URL] {
        guard id.source == self.id, let appID = UInt32(id.value) else { return [] }
        return [URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")!]
    }
    public func installer(for game: SourceGameRecord) throws -> any Installer {
        guard game.id.source == id, UInt32(game.id.value) != nil else { throw SourceFailure.malformedResponse }
        return SteamInstaller(game: game, account: account, runtimeTools: runtimeTools)
    }
    public func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord {
        guard game.id.source == id, UInt32(game.id.value) != nil else { throw SourceFailure.malformedResponse }
        var url = URLComponents(string: "https://store.steampowered.com/api/appdetails")!
        url.queryItems = [URLQueryItem(name: "appids", value: game.id.value), URLQueryItem(name: "l", value: "english")]
        do {
            let (data, response) = try await session.data(from: url.url!)
            guard let http = response as? HTTPURLResponse else { throw SourceFailure.network }
            guard http.statusCode == 200 else { throw http.statusCode == 429 ? SourceFailure.throttled : SourceFailure.unavailable }
            return try Self.parseMetadata(data, for: game)
        } catch { throw sourceFailure(error) }
    }
    static func parseMetadata(_ data: Data, for game: SourceGameRecord) throws -> SourceGameRecord {
        struct Response: Decodable {
            let success: Bool
            let data: Metadata?
        }
        struct Metadata: Decodable {
            let steam_appid: UInt32
            let short_description: String?
            let controller_support: String?
            let genres: [Genre]?
            let platforms: Platforms?
        }
        struct Platforms: Decodable { let windows: Bool?; let mac: Bool? }
        struct Genre: Decodable { let description: String }
        let response = try JSONDecoder().decode([String: Response].self, from: data)[game.id.value]
        guard let response, response.success, let metadata = response.data, String(metadata.steam_appid) == game.id.value else { throw SourceFailure.unavailable }
        var result = game
        if let description = metadata.short_description { result.summary = plainText(description) }
        result.genres = metadata.genres?.map { plainText($0.description) } ?? []
        result.controllerSupport = switch metadata.controller_support { case "full": .full; case "partial": .partial; default: .unknown }
        if let platforms = metadata.platforms {
            result.platforms = (platforms.windows == true ? [GamePlatform.windows] : []) + (platforms.mac == true ? [.macOS] : [])
        }
        result.metadataUpdatedAt = .now
        return result
    }
    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
    }
}

/// Public Steam store pages; also used by the design preview, which has no signed-in source.
public enum SteamStorePage {
    public static func url(for id: GameID) -> URL? {
        guard id.source == SourceID.steam, let appID = UInt32(id.value) else { return nil }
        return URL(string: "https://store.steampowered.com/app/\(appID)/")
    }
    public static func allows(host: String) -> Bool {
        let host = host.lowercased()
        return host == "store.steampowered.com" || host.hasSuffix(".store.steampowered.com")
    }
}
