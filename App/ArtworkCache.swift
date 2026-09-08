import AppKit
import Artwork
import Domain

/// UI access is memory-only. File access and eager image decoding belong to the loader actor.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let memory = NSCache<NSURL, NSImage>()
    private let loader: ArtworkLoader

    init(loader: ArtworkLoader = ArtworkLoader()) {
        self.loader = loader
        memory.totalCostLimit = 160 * 1024 * 1024
    }

    func cachedImage(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        return memory.object(forKey: url as NSURL)
    }

    func cachedImage(for url: URL?, fallbackURL: URL?) -> NSImage? {
        cachedImage(for: url) ?? cachedImage(for: fallbackURL)
    }

    func image(for url: URL?, fallbackURL: URL?) async -> NSImage? {
        if let url, let image = await image(for: url) { return image }
        guard !Task.isCancelled, let fallbackURL, fallbackURL != url else { return nil }
        return await image(for: fallbackURL)
    }

    func image(for url: URL) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cachedImage(for: url) { return image }
        guard let decoded = await loader.image(for: url), !Task.isCancelled else { return nil }
        // Another consumer may have installed this shared request's result while we suspended.
        if let image = cachedImage(for: url) { return image }
        let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        memory.setObject(image, forKey: url as NSURL, cost: decoded.bytesPerRow * decoded.height)
        return image
    }
}

// A Steam header is available for many older games without a portrait library cover.
// Keep this source-specific fallback out of generic artwork URLs (heroes, logos, other stores).
extension Game {
    var coverFallbackURL: URL? {
        guard id.source == "steam", let appID = UInt32(id.value) else { return nil }
        return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")
    }
}
