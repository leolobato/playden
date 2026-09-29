import Foundation

/// One entry of an install, in either generation's terms. Playden saves the list with the install,
/// so download, verify and repair work the same way for gen 1 and gen 2.
public struct GOGFile: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, directory, link }
    /// Relative, `/`-separated, never absolute and never with `..`.
    public var path: String
    public var kind: Kind
    public var target: String?
    public var size: Int64
    public var md5: String?
    public var sha256: String?
    public var executable: Bool
    /// The product whose secure link serves this file, or `GOGFile.dependencyStore`.
    public var product: String
    /// Gen 2: the chunks in file order.
    public var chunks: [GOGChunk]?
    /// Gen 1: where the file starts in its product's `main.bin`.
    public var offset: Int64?

    public static let dependencyStore = "dependencies"

    public init(path: String, kind: Kind = .file, target: String? = nil, size: Int64 = 0, md5: String? = nil, sha256: String? = nil,
                executable: Bool = false, product: String, chunks: [GOGChunk]? = nil, offset: Int64? = nil) {
        self.path = path; self.kind = kind; self.target = target; self.size = size; self.md5 = md5; self.sha256 = sha256
        self.executable = executable; self.product = product; self.chunks = chunks; self.offset = offset
    }

    /// Bytes fetched from the CDN for this file.
    public var downloadSize: Int64 { chunks.map { $0.reduce(0) { $0 + $1.compressedSize } } ?? (kind == .file ? size : 0) }
}

public struct GOGInstallManifest: Codable, Equatable, Sendable {
    public var generation: Int
    public var productID: String
    public var buildID: String
    public var platform: String
    public var versionName: String?
    public var installDirectory: String
    /// GOG's language code for the chosen depots (`en-US`).
    public var language: String
    /// The base game plus the owned DLC whose depots were chosen.
    public var products: [String]
    /// Every dependency the build lists, including installers Playden does not run yet (PRD 10 FR-GOG-22).
    public var dependencies: [String]
    /// Gen 1: the secure-link path, `/<os>/<timestamp>/`.
    public var v1LinkPath: String?
    public var files: [GOGFile]

    public init(generation: Int, productID: String, buildID: String, platform: String, versionName: String?, installDirectory: String,
                language: String, products: [String], dependencies: [String], v1LinkPath: String? = nil, files: [GOGFile]) {
        self.generation = generation; self.productID = productID; self.buildID = buildID; self.platform = platform
        self.versionName = versionName; self.installDirectory = installDirectory; self.language = language
        self.products = products; self.dependencies = dependencies; self.v1LinkPath = v1LinkPath; self.files = files
    }

    public var downloadSize: Int64 { files.reduce(0) { $0 + $1.downloadSize } }
    public var installedSize: Int64 { files.reduce(0) { $0 + ($1.kind == .file ? $1.size : 0) } }

    /// The base product's info file, wherever this platform and generation put it.
    public var infoFile: GOGFile? {
        let names = ["goggame-\(productID).info", ".goggame-\(productID).info"]
        return files.filter { $0.kind == .file && names.contains(($0.path as NSString).lastPathComponent.lowercased()) }
            .min { $0.path.count < $1.path.count }
    }
}

/// Where support files go: outside the game's own tree, inside the install folder.
public enum GOGPaths {
    public static let workDirectory = ".playden-gog"
    public static func support(product: String) -> String { "\(workDirectory)/support/\(product)" }

    /// Where a file flagged `support` goes. Galaxy's install script copies a product's `app/` support
    /// files into the game folder (DOSBox and ScummVM configs live there); the rest stay in the
    /// support folder.
    public static func supportPath(_ path: String, product: String) -> String {
        path.lowercased().hasPrefix("app/") && path.count > 4 ? String(path.dropFirst(4)) : support(product: product) + "/" + path
    }

    /// `\` → `/`, no leading separator, and nothing that leaves the install folder.
    public static func normalize(_ raw: String) throws -> String {
        let components = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0 == "." }) else { throw GOGError.malformed("unsafe path \(raw)") }
        return components.joined(separator: "/")
    }
}

/// Language matching across generations: gen 2 depots list codes (`en-US`, `*`), gen 1 depots list
/// names (`English`, `Neutral`).
public enum GOGLanguage {
    /// Playden's language names (Steam's) → GOG code and English name.
    static let table: [String: (code: String, name: String)] = [
        "english": ("en-US", "English"), "german": ("de-DE", "German"), "french": ("fr-FR", "French"),
        "spanish": ("es-ES", "Spanish"), "latam": ("es-MX", "Latin American Spanish"), "italian": ("it-IT", "Italian"),
        "polish": ("pl-PL", "Polish"), "russian": ("ru-RU", "Russian"), "brazilian": ("pt-BR", "Brazilian Portuguese"),
        "portuguese": ("pt-PT", "Portuguese"), "japanese": ("ja-JP", "Japanese"), "koreana": ("ko-KR", "Korean"),
        "schinese": ("zh-Hans", "Chinese Simplified"), "tchinese": ("zh-Hant", "Chinese Traditional"), "czech": ("cs-CZ", "Czech"),
        "turkish": ("tr-TR", "Turkish"), "dutch": ("nl-NL", "Dutch"), "hungarian": ("hu-HU", "Hungarian"),
        "swedish": ("sv-SE", "Swedish"), "danish": ("da-DK", "Danish"), "finnish": ("fi-FI", "Finnish"), "norwegian": ("nb-NO", "Norwegian"),
        "ukrainian": ("uk-UA", "Ukrainian"), "greek": ("el-GR", "Greek"), "romanian": ("ro-RO", "Romanian"),
    ]
    public static let english = "english"

    public static func code(for language: String) -> String { table[language.lowercased()]?.code ?? "en-US" }

    /// True when a depot's language list covers `language` (a Playden language name).
    public static func depot(_ languages: [String], covers language: String) -> Bool {
        let entry = table[language.lowercased()] ?? table[english]!
        let wanted: Set<String> = [entry.code.lowercased(), entry.name.lowercased(), String(entry.code.prefix(2)).lowercased(), language.lowercased()]
        return languages.contains { wanted.contains($0.lowercased()) }
    }

    public static func isNeutral(_ languages: [String]) -> Bool {
        languages.contains { $0 == "*" || $0.lowercased() == "neutral" }
    }
}

/// Picks depots for an install and flattens them into a `GOGInstallManifest`.
public enum GOGDepotSelection {
    /// Products to install: the base game, and the build's DLC that the account owns.
    public static func products(base: String, listed: [String], owned: Set<String>) -> [String] {
        [base] + listed.filter { $0 != base && owned.contains($0) }
    }

    /// The language to install: the requested one when the base game has it, else English.
    public static func language(_ requested: String, available: [[String]]) -> String {
        available.contains { GOGLanguage.depot($0, covers: requested) } ? requested.lowercased() : GOGLanguage.english
    }

    /// Gen 2 depots for these products and language. 64-bit depots win where a product has both.
    public static func depots(_ manifest: GOGBuildManifestV2, products: [String], language: String) -> [GOGBuildManifestV2.Depot] {
        let chosen = manifest.depots.filter { depot in
            products.contains(depot.productId.value)
                && (GOGLanguage.isNeutral(depot.languages) || GOGLanguage.depot(depot.languages, covers: language))
        }
        return chosen.filter { depot in
            guard let bitness = depot.osBitness, !bitness.isEmpty, !bitness.contains("64"), !bitness.contains("*") else { return true }
            // A 32-bit-only depot is kept only when its product has no 64-bit depot.
            return !chosen.contains { $0.productId == depot.productId && ($0.osBitness?.contains("64") ?? false) }
        }
    }

    /// Gen 1 depots with files for these products and language; `redist` depots are dependencies.
    public static func depots(_ repository: GOGRepositoryV1, products: [String], language: String) -> [GOGRepositoryV1.Depot] {
        repository.product.depots.filter { depot in
            guard depot.redist == nil, depot.manifest != nil else { return false }
            let ids = depot.gameIDs?.map(\.value) ?? []
            let languages = depot.languages ?? ["Neutral"]
            return ids.contains(where: products.contains)
                && (GOGLanguage.isNeutral(languages) || GOGLanguage.depot(languages, covers: language))
        }
    }

    public static func files(_ manifest: GOGDepotManifestV2, product: String) throws -> [GOGFile] {
        try manifest.items.map { item in
            let flags = Set(item.flags ?? [])
            var path = try GOGPaths.normalize(item.path)
            if flags.contains("support") { path = GOGPaths.supportPath(path, product: product) }
            switch item.type {
            case "DepotFile":
                return GOGFile(path: path, size: item.chunks.reduce(0) { $0 + $1.size },
                               md5: item.md5 ?? (item.chunks.count == 1 ? item.chunks[0].md5 : nil), sha256: item.sha256,
                               executable: flags.contains("executable"), product: product, chunks: item.chunks)
            case "DepotLink":
                return GOGFile(path: path, kind: .link, target: item.target?.replacingOccurrences(of: "\\", with: "/"), product: product)
            default:
                return GOGFile(path: path, kind: .directory, product: product)
            }
        }
    }

    public static func files(_ manifest: GOGDepotManifestV1, product: String) throws -> [GOGFile] {
        try manifest.files.map { file in
            var path = try GOGPaths.normalize(file.path)
            if file.support == true { path = GOGPaths.supportPath(path, product: product) }
            if file.directory == true { return GOGFile(path: path, kind: .directory, product: product) }
            if let target = file.target, file.symlinkType != nil || file.size == nil {
                return GOGFile(path: path, kind: .link, target: target, product: product)
            }
            // `url` names the blob, `<product>/main.bin`; its first part is the product that serves it.
            let blobProduct = file.url?.split(separator: "/").first.map(String.init) ?? product
            return GOGFile(path: path, size: file.size?.value ?? 0, md5: file.hash, executable: file.executable == true,
                           product: blobProduct, offset: file.offset?.value ?? 0)
        }
    }

    /// Later depots win on a shared path (DLC over base, as lgogdownloader does); order is kept.
    public static func merge(_ lists: [[GOGFile]]) -> [GOGFile] {
        var index: [String: Int] = [:], result: [GOGFile] = []
        for file in lists.joined() {
            let key = file.path.lowercased()
            if let existing = index[key] { result[existing] = file } else { index[key] = result.count; result.append(file) }
        }
        return result
    }
}
