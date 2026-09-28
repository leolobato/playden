import Foundation

public enum EpicPlatform: String, Sendable, Codable { case windows = "Windows", mac = "Mac" }

/// Something the account can install on a platform (`/launcher/api/public/assets`).
public struct EpicAsset: Codable, Equatable, Sendable {
    public var appName: String
    public var labelName: String?
    public var buildVersion: String
    public var catalogItemId: String
    public var namespace: String
    public var assetId: String?
    public var sidecarRvn: Int?
}

/// An owned item from the library service. Covers items that have no asset, such as EA and Ubisoft titles.
public struct EpicLibraryRecord: Codable, Equatable, Sendable {
    public var namespace: String
    public var catalogItemId: String
    public var appName: String?
    public var sandboxType: String?
    public var acquisitionDate: String?
}

public struct EpicCatalogItem: Codable, Equatable, Sendable {
    public struct KeyImage: Codable, Equatable, Sendable { public var type: String; public var url: String }
    public struct Category: Codable, Equatable, Sendable { public var path: String }
    public struct Attribute: Codable, Equatable, Sendable { public var type: String?; public var value: String }
    public struct Release: Codable, Equatable, Sendable { public var appId: String?; public var platform: [String]? }
    public struct Reference: Codable, Equatable, Sendable { public var id: String }

    public var id: String
    public var title: String
    public var description: String?
    public var namespace: String?
    public var keyImages: [KeyImage]?
    public var categories: [Category]?
    public var customAttributes: [String: Attribute]?
    public var releaseInfo: [Release]?
    public var mainGameItem: Reference?
    public var developer: String?
    public var creationDate: String?

    public func attribute(_ key: String) -> String? { customAttributes?[key]?.value }
    public func image(_ types: [String]) -> URL? {
        for type in types { if let hit = keyImages?.first(where: { $0.type == type }), let url = URL(string: hit.url) { return url } }
        return nil
    }
    public var categoryPaths: [String] { categories?.map(\.path) ?? [] }
    public var isDLC: Bool { mainGameItem != nil }
    /// EA app or Ubisoft Connect titles can't be installed without that launcher.
    public var thirdPartyStore: String? {
        attribute("ThirdPartyManagedApp") ?? attribute("ThirdPartyManagedProvider")
            ?? (attribute("partnerLinkType") == "ubisoft" ? "Ubisoft Connect" : nil)
    }
    /// Absent means offline launch is allowed.
    public var canRunOffline: Bool { attribute("CanRunOffline")?.lowercased() != "false" }
    public var requiresOwnershipToken: Bool { attribute("OwnershipToken")?.lowercased() == "true" }
    public var additionalCommandLine: String? { attribute("AdditionalCommandLine") ?? attribute("AdditionalCommandline") }
}

/// Where to download a build's manifest from, and the chunk CDNs next to it.
public struct EpicManifestLocation: Equatable, Sendable {
    public var manifestURLs: [URL]
    /// Chunk bases: each manifest URL's folder, without its CDN token.
    public var baseURLs: [URL]
    public var sha1: String
    public var buildVersion: String
    public var secrets: [String: String]
    public var deploymentID: String?
}

public struct EpicLibraryAPI: Sendable {
    let http: EpicHTTP

    public init(config: EpicClientConfig = .default, transport: any EpicTransport = URLSession.shared,
                pause: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        http = EpicHTTP(config: config, transport: transport, pause: pause)
    }

    public func assets(platform: EpicPlatform, accessToken: String) async throws -> [EpicAsset] {
        try await http.json([EpicAsset].self, "GET",
                            http.url(http.config.launcherHost, "/launcher/api/public/assets/\(platform.rawValue)", [.init(name: "label", value: "Live")]),
                            auth: .bearer(accessToken))
    }

    public func libraryItems(accessToken: String) async throws -> [EpicLibraryRecord] {
        struct Page: Decodable {
            struct Meta: Decodable { var nextCursor: String? }
            var records: [EpicLibraryRecord]; var responseMetadata: Meta?
        }
        var records: [EpicLibraryRecord] = []
        var cursor: String?
        repeat {
            var query = [URLQueryItem(name: "includeMetadata", value: "true")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            let page = try await http.json(Page.self, "GET", http.url(http.config.libraryHost, "/library/api/public/items", query),
                                           auth: .bearer(accessToken))
            records += page.records
            cursor = page.responseMetadata?.nextCursor.flatMap { $0.isEmpty || $0 == cursor ? nil : $0 }
        } while cursor != nil
        return records
    }

    public func catalogItem(namespace: String, catalogItemID: String, accessToken: String,
                            country: String = "US", locale: String = "en-US") async throws -> EpicCatalogItem? {
        let url = http.url(http.config.catalogHost, "/catalog/api/shared/namespace/\(namespace)/bulk/items", [
            .init(name: "id", value: catalogItemID), .init(name: "includeDLCDetails", value: "true"),
            .init(name: "includeMainGameDetails", value: "true"), .init(name: "country", value: country), .init(name: "locale", value: locale),
        ])
        return try await http.json([String: EpicCatalogItem].self, "GET", url, auth: .bearer(accessToken))[catalogItemID]
    }

    public func manifestLocation(platform: EpicPlatform, namespace: String, catalogItemID: String, appName: String,
                                 accessToken: String) async throws -> EpicManifestLocation {
        struct Response: Decodable {
            struct Element: Decodable {
                struct Manifest: Decodable {
                    struct Param: Decodable { var name: String; var value: String }
                    var uri: String; var queryParams: [Param]?
                }
                struct Sidecar: Decodable { var config: String? }
                var buildVersion: String?; var hash: String; var manifests: [Manifest]
                var secrets: [String: String]?; var sidecar: Sidecar?
            }
            var elements: [Element]
        }
        let path = "/launcher/api/public/assets/v2/platform/\(platform.rawValue)/namespace/\(namespace)/catalogItem/\(catalogItemID)/app/\(appName)/label/Live"
        let response = try await http.json(Response.self, "GET", http.url(http.config.launcherHost, path), auth: .bearer(accessToken))
        guard response.elements.count == 1, let element = response.elements.first else {
            throw EpicError.malformed("manifest API returned \(response.elements.count) elements")
        }
        var manifestURLs: [URL] = []
        var baseURLs: [URL] = []
        for manifest in element.manifests {
            guard var components = URLComponents(string: manifest.uri) else { continue }
            if let params = manifest.queryParams, !params.isEmpty { components.queryItems = params.map { URLQueryItem(name: $0.name, value: $0.value) } }
            if let url = components.url { manifestURLs.append(url) }
            if let base = URL(string: manifest.uri)?.deletingLastPathComponent(), !baseURLs.contains(base) { baseURLs.append(base) }
        }
        guard !manifestURLs.isEmpty else { throw EpicError.malformed("manifest API returned no URLs") }
        var deploymentID: String?
        if let config = element.sidecar?.config, let data = config.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            deploymentID = json["deploymentId"] as? String
        }
        return EpicManifestLocation(manifestURLs: manifestURLs, baseURLs: baseURLs, sha1: element.hash.lowercased(),
                                    buildVersion: element.buildVersion ?? "", secrets: element.secrets ?? [:], deploymentID: deploymentID)
    }

    /// Downloads the manifest from the first CDN that answers with bytes matching the API's hash.
    public func manifest(at location: EpicManifestLocation) async throws -> (EpicManifest, Data) {
        var lastError: Error = EpicError.malformed("no manifest URL")
        for url in location.manifestURLs {
            do {
                let data = try await http.request("GET", url, auth: .none)
                guard EpicCodec.sha1(data).hexString == location.sha1 else { throw EpicError.hashMismatch("manifest") }
                return (try EpicManifest.parse(data, secrets: location.secrets), data)
            } catch EpicError.cancelled { throw EpicError.cancelled }
            catch { lastError = error }
        }
        throw lastError
    }

    /// The `.ovt` file bytes that Denuvo-protected games read through `-epicovt`.
    public func ownershipToken(accountID: String, namespace: String, catalogItemID: String, accessToken: String) async throws -> Data {
        try await http.request("POST", http.url(http.config.ecommerceHost,
                                                "/ecommerceintegration/api/public/platforms/EPIC/identities/\(accountID)/ownershipToken"),
                               auth: .bearer(accessToken), form: ["nsCatalogItemId": "\(namespace):\(catalogItemID)"])
    }
}
