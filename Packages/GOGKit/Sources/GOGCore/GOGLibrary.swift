import Foundation

/// What Playden keeps from a gamesdb entry (PRD 10 FR-GOG-8 to FR-GOG-10).
public struct GOGGameEntry: Codable, Equatable, Sendable {
    public var productID: String
    /// `game`, `dlc`, `mod` or `spam`.
    public var type: String
    public var visibleInLibrary: Bool
    public var title: String
    public var summary: String?
    public var genres: [String]
    public var developers: [String]
    public var publishers: [String]
    public var releaseDate: String?
    /// gamesdb slugs: `windows`, `osx`, `linux`.
    public var systems: [String]
    public var cover: URL?
    public var hero: URL?
    public var logo: URL?

    /// Only visible games become tiles; DLC, mods and bundles ("spam") do not.
    public var isListedGame: Bool { type == "game" && visibleInLibrary }

    public init(productID: String, type: String, visibleInLibrary: Bool, title: String, summary: String? = nil, genres: [String] = [],
                developers: [String] = [], publishers: [String] = [], releaseDate: String? = nil, systems: [String] = [],
                cover: URL? = nil, hero: URL? = nil, logo: URL? = nil) {
        self.productID = productID; self.type = type; self.visibleInLibrary = visibleInLibrary; self.title = title; self.summary = summary
        self.genres = genres; self.developers = developers; self.publishers = publishers; self.releaseDate = releaseDate
        self.systems = systems; self.cover = cover; self.hero = hero; self.logo = logo
    }

    /// gamesdb image objects carry `url_format` with `{formatter}` and `{ext}`; the query is kept.
    static func image(_ value: GOGJSON?) -> URL? {
        guard let format = value?["url_format"]?.string else { return nil }
        return URL(string: format.replacingOccurrences(of: "{formatter}", with: "").replacingOccurrences(of: "{ext}", with: "jpg"))
    }

    static func localized(_ value: GOGJSON?) -> String? { value?["en-US"]?.string ?? value?["*"]?.string ?? value?.string }

    public init(gamesDB entry: GOGJSON, productID: String) {
        let game = entry["game"]
        self.init(productID: productID, type: entry["type"]?.string ?? "game",
                  visibleInLibrary: game?["visible_in_library"] == .bool(true),
                  title: Self.localized(entry["title"]) ?? Self.localized(game?["title"]) ?? "",
                  summary: Self.localized(entry["summary"]) ?? Self.localized(game?["summary"]),
                  genres: game?["genres"]?.array.compactMap { Self.localized($0["name"]) } ?? [],
                  developers: game?["developers"]?.array.compactMap { $0["name"]?.string } ?? [],
                  publishers: game?["publishers"]?.array.compactMap { $0["name"]?.string } ?? [],
                  releaseDate: entry["first_release_date"]?.string ?? game?["first_release_date"]?.string,
                  systems: entry["supported_operating_systems"]?.array.compactMap { $0["slug"]?.string } ?? [],
                  cover: Self.image(game?["vertical_cover"]),
                  hero: Self.image(game?["background"]) ?? Self.image(game?["horizontal_artwork"]))
    }
}

public enum GOGGamesDBResult: Equatable, Sendable {
    case entry(GOGGameEntry, etag: String?)
    case notModified
    case missing
}

extension GOGAPI {
    /// gamesdb with `If-None-Match`, so an unchanged product costs one short answer (FR-GOG-11).
    public func gamesDBEntry(productID: String, etag: String?) async throws -> GOGGamesDBResult {
        let url = GOGHTTP.url("gamesdb.gog.com", "/platforms/gog/external_releases/\(productID)")
        let (data, response) = try await http.request(url, headers: etag.map { ["If-None-Match": $0] } ?? [:], accept: 200...404)
        switch response.statusCode {
        case 304: return .notModified
        case 404: return .missing
        case 200: return .entry(GOGGameEntry(gamesDB: try GOGHTTP.decode(GOGJSON.self, data), productID: productID),
                                etag: response.value(forHTTPHeaderField: "ETag"))
        default: throw GOGError.http(status: response.statusCode, code: nil, message: "gamesdb")
        }
    }

    /// The v2 products API's logo, used only when it is a PNG (the jpg ones are key art, not a logo).
    public func logo(productID: String) async throws -> URL? {
        let url = GOGHTTP.url("api.gog.com", "/v2/games/\(productID)", [.init(name: "locale", value: "en-US")])
        let (data, _) = try await http.request(url, accept: 200...404)
        guard let href = (try? JSONDecoder().decode(GOGJSON.self, from: data))?["_links"]?["logo"]?["href"]?.string,
              href.lowercased().hasSuffix(".png") else { return nil }
        return URL(string: href.hasPrefix("//") ? "https:" + href : href)
    }

    public func displayName(accessToken: String) async throws -> String? {
        try await userData(accessToken: accessToken)["username"]?.string
    }
}
