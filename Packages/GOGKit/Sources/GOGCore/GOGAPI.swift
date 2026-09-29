import Foundation

/// One entry of the builds list. Asking for generation 2 returns both generations.
public struct GOGBuild: Decodable, Equatable, Sendable {
    public struct Endpoint: Decodable, Equatable, Sendable {
        public var endpoint_name: String
        public var url: String?
        public var url_format: String
        public var parameters: [String: GOGJSON]
        public var priority: Int?
        public var fallback_only: Bool?
        public var supports_generation: [Int]?

        /// Fills `url_format` with the parameters, appending `suffix` to `path` first.
        public func url(appendingPath suffix: String) -> URL? {
            var values = parameters
            if case .string(let path)? = values["path"] { values["path"] = .string(path + suffix) }
            var text = url_format
            for (key, value) in values { text = text.replacingOccurrences(of: "{\(key)}", with: value.text) }
            return URL(string: text)
        }
    }
    public var build_id: String
    public var product_id: String
    public var os: String
    public var branch: String?
    public var version_name: String?
    public var generation: Int
    public var legacy_build_id: Int?
    public var link: String?
    public var urls: [Endpoint]?
}

/// A loose JSON value, for responses whose shape varies (secure-link parameters, gamesdb).
public enum GOGJSON: Decodable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([GOGJSON]), object([String: GOGJSON]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([GOGJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: GOGJSON].self)) }
    }

    public var text: String {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): String(b)
        case .null: ""
        case .array, .object: ""
        }
    }
    public subscript(key: String) -> GOGJSON? { if case .object(let o) = self { o[key] } else { nil } }
    public var array: [GOGJSON] { if case .array(let a) = self { a } else { [] } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
}

public struct GOGAPI: Sendable {
    let http: GOGHTTP

    public init(config: GOGClientConfig = .default, transport: any GOGTransport = URLSession.shared,
                pause: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        http = GOGHTTP(config: config, transport: transport, pause: pause)
    }

    // MARK: Library

    public func ownedProductIDs(accessToken: String) async throws -> [Int] {
        struct Response: Decodable { var owned: [Int] }
        return try await http.json(Response.self, GOGHTTP.url("embed.gog.com", "/user/data/games"), bearer: accessToken).owned
    }

    public func userData(accessToken: String) async throws -> GOGJSON {
        try await http.json(GOGJSON.self, GOGHTTP.url("embed.gog.com", "/userData.json"), bearer: accessToken)
    }

    /// Pages of `galaxy-library.gog.com/users/<id>/releases`, followed to the end.
    public func libraryReleases(userID: String, accessToken: String) async throws -> [GOGJSON] {
        var items: [GOGJSON] = [], token: String?
        repeat {
            let query = token.map { [URLQueryItem(name: "page_token", value: $0)] } ?? []
            let page = try await http.json(GOGJSON.self, GOGHTTP.url("galaxy-library.gog.com", "/users/\(userID)/releases", query), bearer: accessToken)
            items += page["items"]?.array ?? []
            token = page["next_page_token"]?.string
        } while token != nil
        return items
    }

    /// Nil when gamesdb has no entry for the product.
    public func gamesDB(productID: Int) async throws -> GOGJSON? {
        let url = GOGHTTP.url("gamesdb.gog.com", "/platforms/gog/external_releases/\(productID)")
        let (data, response) = try await http.request(url, accept: 200...404)
        return response.statusCode == 404 ? nil : try GOGHTTP.decode(GOGJSON.self, data)
    }

    // MARK: Content system

    public func builds(productID: Int, os: String, accessToken: String?) async throws -> [GOGBuild] {
        struct Response: Decodable { var items: [GOGBuild] }
        let url = GOGHTTP.url("content-system.gog.com", "/products/\(productID)/os/\(os)/builds",
                              [.init(name: "generation", value: "2"), .init(name: "_version", value: "2")])
        return try await http.json(Response.self, url, bearer: accessToken).items
    }

    /// The build or depot manifest JSON, inflated when it is zlib.
    public func manifest(at url: URL) async throws -> Data {
        try GOGCodec.maybeInflate(try await http.request(url).0)
    }

    /// Tries each CDN in turn; the first that answers wins.
    public func manifest(from urls: [URL]) async throws -> Data {
        var last: Error = GOGError.malformed("no manifest URL")
        for url in urls {
            do { return try await manifest(at: url) }
            catch GOGError.cancelled { throw GOGError.cancelled }
            catch { last = error }
        }
        throw last
    }

    /// Gen 2 manifests live at `<cdn>/content-system/v2/meta/ab/cd/<hash>`.
    public static func v2MetaURL(_ hash: String, cdn: String = "https://gog-cdn-fastly.gog.com") -> URL {
        URL(string: "\(cdn)/content-system/v2/meta/\(GOGCodec.galaxyPath(hash))")!
    }

    /// The raw secure-link response for a product (gen 2: `path=/`; gen 1: `/<os>/<timestamp>/` with `type=depot`).
    public func secureLink(productID: String, generation: Int, path: String, accessToken: String) async throws -> [GOGBuild.Endpoint] {
        struct Response: Decodable { var urls: [GOGBuild.Endpoint] }
        var query: [URLQueryItem] = [.init(name: "_version", value: "2"), .init(name: "path", value: path)]
        query.append(generation == 2 ? .init(name: "generation", value: "2") : .init(name: "type", value: "depot"))
        let url = GOGHTTP.url("content-system.gog.com", "/products/\(productID)/secure_link", query)
        return try await http.json(Response.self, url, bearer: accessToken).urls
    }

    /// The dependency repository (public).
    public func dependencyRepository() async throws -> GOGDependencyRepository {
        struct Pointer: Decodable { var repository_manifest: String }
        let pointer = try await http.json(Pointer.self, GOGHTTP.url("content-system.gog.com", "/dependencies/repository", [.init(name: "generation", value: "2")]))
        guard let url = URL(string: pointer.repository_manifest) else { throw GOGError.malformed("dependency repository URL") }
        return try GOGHTTP.decode(GOGDependencyRepository.self, try await manifest(at: url))
    }

    /// CDN endpoints for the public dependency store; its URLs are not signed.
    public func dependencyStore() async throws -> [GOGBuild.Endpoint] {
        struct Response: Decodable { var urls: [GOGBuild.Endpoint] }
        let url = GOGHTTP.url("content-system.gog.com", "/open_link", [
            .init(name: "generation", value: "2"), .init(name: "_version", value: "2"), .init(name: "path", value: "/dependencies/store/"),
        ])
        return try await http.json(Response.self, url).urls
    }

    /// Fetches a gen 2 chunk, checks both hashes and returns the inflated bytes.
    public func chunk(compressedMD5: String, md5: String, from endpoint: GOGBuild.Endpoint) async throws -> Data {
        guard let url = endpoint.url(appendingPath: "/" + GOGCodec.galaxyPath(compressedMD5)) else { throw GOGError.malformed("chunk URL") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(http.config.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.transport.send(request)
        guard response.statusCode == 200 else { throw GOGError.http(status: response.statusCode, code: nil, message: "chunk") }
        guard GOGCodec.md5(data) == compressedMD5 else { throw GOGError.hashMismatch("compressed chunk \(compressedMD5)") }
        let inflated = try GOGCodec.inflateZlib(data)
        guard GOGCodec.md5(inflated) == md5 else { throw GOGError.hashMismatch("chunk \(md5)") }
        return inflated
    }
}
