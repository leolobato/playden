import Foundation

/// A build resolved into the files to install.
public struct GOGResolution: Sendable {
    public var build: GOGBuild
    public var manifest: GOGInstallManifest
    /// The build manifest as GOG served it, saved with the install for later updates.
    public var buildManifest: Data
}

/// Turns a product and platform into a `GOGInstallManifest` (PRD 10 FR-GOG-13, FR-GOG-14, FR-GOG-21).
public struct GOGResolver: Sendable {
    let api: GOGAPI
    public init(api: GOGAPI = GOGAPI()) { self.api = api }

    /// The first build on the default branch; the list is newest first.
    public static func defaultBuild(_ builds: [GOGBuild]) -> GOGBuild? { builds.first { $0.branch == nil } }

    /// CDN hosts in the order to try them: higher priority first, fallback-only ones last.
    public static func ordered(_ endpoints: [GOGBuild.Endpoint]) -> [GOGBuild.Endpoint] {
        endpoints.enumerated().sorted { a, b in
            let fa = a.element.fallback_only ?? false, fb = b.element.fallback_only ?? false
            if fa != fb { return !fa }
            let pa = a.element.priority ?? 0, pb = b.element.priority ?? 0
            return pa != pb ? pa > pb : a.offset < b.offset
        }.map(\.element)
    }

    /// `https://host` of each manifest endpoint, for the depot manifests next to the build manifest.
    static func cdnBases(_ build: GOGBuild) -> [String] {
        let links = ordered(build.urls ?? []).compactMap { $0.url.flatMap(URL.init(string:)) } + (build.link.flatMap(URL.init(string:)).map { [$0] } ?? [])
        var seen = Set<String>(), bases: [String] = []
        for url in links {
            guard let scheme = url.scheme, let host = url.host else { continue }
            let base = "\(scheme)://\(host)"
            if seen.insert(base).inserted { bases.append(base) }
        }
        return bases.isEmpty ? ["https://gog-cdn-fastly.gog.com"] : bases
    }

    public func resolve(productID: String, os: String, language: String, owned: Set<String>, accessToken: String) async throws -> GOGResolution {
        guard let id = Int(productID) else { throw GOGError.malformed("product ID \(productID)") }
        let builds = try await api.builds(productID: id, os: os, accessToken: accessToken)
        guard let build = Self.defaultBuild(builds) else { throw GOGError.noBuild(os) }
        let bases = Self.cdnBases(build)
        let links = Self.ordered(build.urls ?? []).compactMap { $0.url.flatMap(URL.init(string:)) } + (build.link.flatMap(URL.init(string:)).map { [$0] } ?? [])
        let raw = try await api.manifest(from: links)
        switch build.generation {
        case 2: return try await resolveV2(build: build, raw: raw, os: os, language: language, owned: owned, bases: bases)
        case 1: return try await resolveV1(build: build, raw: raw, os: os, language: language, owned: owned, bases: bases)
        default: throw GOGError.malformed("build generation \(build.generation)")
        }
    }

    private func resolveV2(build: GOGBuild, raw: Data, os: String, language requested: String, owned: Set<String>, bases: [String]) async throws -> GOGResolution {
        let meta = try GOGHTTP.decode(GOGBuildManifestV2.self, raw)
        let base = meta.baseProductId.value
        let products = GOGDepotSelection.products(base: base, listed: meta.products?.map(\.productId.value) ?? [], owned: owned)
        let language = GOGDepotSelection.language(requested, available: meta.depots.filter { $0.productId.value == base }.map(\.languages))
        let depots = GOGDepotSelection.depots(meta, products: products, language: language)
        var lists: [[GOGFile]] = []
        for depot in depots {
            let urls = bases.map { URL(string: "\($0)/content-system/v2/meta/\(GOGCodec.galaxyPath(depot.manifest))")! }
            let manifest = try GOGHTTP.decode(GOGDepotManifestV2.self, try await api.manifest(from: urls))
            lists.append(try GOGDepotSelection.files(manifest, product: depot.productId.value))
        }
        lists.append(try await dependencyFiles(meta.dependencies ?? [], bases: bases))
        let manifest = GOGInstallManifest(generation: 2, productID: base, buildID: build.build_id, platform: os, versionName: build.version_name,
                                          installDirectory: meta.installDirectory, language: GOGLanguage.code(for: language),
                                          products: products, dependencies: meta.dependencies ?? [], files: GOGDepotSelection.merge(lists))
        return GOGResolution(build: build, manifest: manifest, buildManifest: raw)
    }

    private func resolveV1(build: GOGBuild, raw: Data, os: String, language requested: String, owned: Set<String>, bases: [String]) async throws -> GOGResolution {
        let repository = try GOGHTTP.decode(GOGRepositoryV1.self, raw)
        let product = repository.product
        let base = product.rootGameID.value
        let products = GOGDepotSelection.products(base: base, listed: product.gameIDs?.map(\.gameID.value) ?? [], owned: owned)
        let language = GOGDepotSelection.language(requested, available: product.depots.filter {
            $0.redist == nil && ($0.gameIDs?.contains(GOGID(base)) ?? false)
        }.map { $0.languages ?? [] })
        let depots = GOGDepotSelection.depots(repository, products: products, language: language)
        let timestamp = String(product.timestamp.value)
        var lists: [[GOGFile]] = []
        for depot in depots {
            guard let name = depot.manifest, let owner = depot.gameIDs?.first?.value else { continue }
            let urls = bases.map { URL(string: "\($0)/content-system/v1/manifests/\(owner)/\(os)/\(timestamp)/\(name)")! }
            let manifest = try GOGHTTP.decode(GOGDepotManifestV1.self, try await api.manifest(from: urls))
            lists.append(try GOGDepotSelection.files(manifest, product: owner))
        }
        let dependencies = product.depots.compactMap(\.redist)
        lists.append(try await dependencyFiles(dependencies, bases: bases))
        let manifest = GOGInstallManifest(generation: 1, productID: base, buildID: build.build_id, platform: os, versionName: build.version_name,
                                          installDirectory: product.installDirectory, language: GOGLanguage.code(for: language),
                                          products: products, dependencies: dependencies, v1LinkPath: "/\(os)/\(timestamp)/",
                                          files: GOGDepotSelection.merge(lists))
        return GOGResolution(build: build, manifest: manifest, buildManifest: raw)
    }

    /// Files of the dependencies that belong in the game folder (DOSBox, ScummVM). Installers are skipped.
    private func dependencyFiles(_ ids: [String], bases: [String]) async throws -> [GOGFile] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids.map { $0.lowercased() })
        let repository = try await api.dependencyRepository()
        var files: [GOGFile] = []
        for depot in repository.depots where wanted.contains(depot.dependencyId.lowercased()) && depot.isGameFolderDependency {
            let urls = bases.map { URL(string: "\($0)/content-system/v2/dependencies/meta/\(GOGCodec.galaxyPath(depot.manifest))")! }
            let manifest = try GOGHTTP.decode(GOGDepotManifestV2.self, try await api.manifest(from: urls))
            files += try GOGDepotSelection.files(manifest, product: GOGFile.dependencyStore)
        }
        return files
    }
}
