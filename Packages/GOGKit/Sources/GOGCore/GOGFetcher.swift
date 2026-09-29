import Foundation

/// Where download bytes come from. Tests serve them from memory.
public protocol GOGContentFetching: Sendable {
    /// A gen 2 chunk as stored on the CDN (zlib).
    func chunk(_ chunk: GOGChunk, product: String) async throws -> Data
    /// Gen 1: bytes `offset..<offset+length` of the product's `main.bin`.
    func range(product: String, offset: Int64, length: Int64) async throws -> Data
}

/// Fetches from GOG's CDNs with secure links. Each product has its own link (FR-GOG-15), which is
/// fetched again when a CDN answers 401 or 403. Failures rotate through the CDNs with backoff.
public actor GOGCDNFetcher: GOGContentFetching {
    let api: GOGAPI
    let generation: Int
    let v1LinkPath: String?
    let accessToken: @Sendable () async throws -> String
    let transport: any GOGTransport
    let pause: @Sendable (Double) async throws -> Void
    public var attempts = 6
    private var links: [String: [GOGBuild.Endpoint]] = [:]

    /// CDN requests go through `transport`, which defaults to the API's, and retry with its pause.
    public init(manifest: GOGInstallManifest, api: GOGAPI = GOGAPI(), transport: (any GOGTransport)? = nil,
                pause: (@Sendable (Double) async throws -> Void)? = nil,
                accessToken: @escaping @Sendable () async throws -> String) {
        self.api = api; generation = manifest.generation; v1LinkPath = manifest.v1LinkPath
        self.accessToken = accessToken; self.transport = transport ?? api.http.transport; self.pause = pause ?? api.http.pause
    }

    private func endpoints(_ product: String, refresh: Bool) async throws -> [GOGBuild.Endpoint] {
        if !refresh, let cached = links[product] { return cached }
        let fresh: [GOGBuild.Endpoint]
        if product == GOGFile.dependencyStore {
            fresh = try await api.dependencyStore()
        } else {
            let path = generation == 2 ? "/" : (v1LinkPath ?? "/")
            fresh = try await api.secureLink(productID: product, generation: generation, path: path, accessToken: try await accessToken())
        }
        let ordered = GOGResolver.ordered(fresh)
        guard !ordered.isEmpty else { throw GOGError.malformed("no CDN for product \(product)") }
        links[product] = ordered
        return ordered
    }

    public func chunk(_ chunk: GOGChunk, product: String) async throws -> Data {
        try await get(product: product, suffix: "/" + GOGCodec.galaxyPath(chunk.compressedMd5), range: nil)
    }

    public func range(product: String, offset: Int64, length: Int64) async throws -> Data {
        let data = try await get(product: product, suffix: "/main.bin", range: offset..<(offset + length))
        guard Int64(data.count) == length else { throw GOGError.malformed("range returned \(data.count) of \(length) bytes") }
        return data
    }

    private func get(product: String, suffix: String, range: Range<Int64>?) async throws -> Data {
        var refresh = false
        var last: Error = GOGError.network("no attempt")
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let list = try await endpoints(product, refresh: refresh)
            refresh = false
            let endpoint = list[attempt % list.count]
            // The dependency store's `url` is a plain base; secure links fill a template.
            let url = product == GOGFile.dependencyStore
                ? endpoint.url.flatMap { URL(string: $0 + suffix) } : endpoint.url(appendingPath: suffix)
            guard let url else { throw GOGError.malformed("CDN URL") }
            var request = URLRequest(url: url, timeoutInterval: 30)
            if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
            do {
                let (data, response) = try await transport.send(request)
                switch response.statusCode {
                case 200, 206: return data
                case 401, 403: refresh = true; last = GOGError.unauthorized
                default: last = GOGError.http(status: response.statusCode, code: nil, message: "CDN")
                }
            } catch is CancellationError { throw GOGError.cancelled }
            catch let error as URLError where error.code == .cancelled { throw GOGError.cancelled }
            catch { last = GOGError.network(error.localizedDescription) }
            if attempt + 1 < attempts, attempt + 1 >= list.count { try await pause(Double(min(1 << (attempt / list.count), 16))) }
        }
        throw last
    }
}
