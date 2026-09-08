import Foundation

public struct FileVerificationProgress: Sendable {
    public let bytesChecked: UInt64
    public let bytesTotal: UInt64
    public init(bytesChecked: UInt64, bytesTotal: UInt64) {
        self.bytesChecked = bytesChecked; self.bytesTotal = bytesTotal
    }
}

public struct DownloadProgress: Sendable {
    public let depotID: UInt32
    public let file: String
    public let bytesDone: UInt64
    public let bytesTotal: UInt64
    /// Fresh validated/committed bytes during this invocation, excluding retained files and chunks.
    public let bytesWritten: UInt64?
    /// File-local disk verification, separate from assembled/downloaded bytes.
    public let verification: FileVerificationProgress?
    public init(depotID: UInt32, file: String, bytesDone: UInt64, bytesTotal: UInt64, bytesWritten: UInt64? = nil, verification: FileVerificationProgress? = nil) {
        self.depotID = depotID; self.file = file; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.bytesWritten = bytesWritten; self.verification = verification
    }
}

/// Downloads selected depots of an app and assembles them into
/// `<gamesDir>/app_<appid>/<Name>/` (the layout poc/fetch-depots.sh established).
public struct DownloadEngine {
    public let cm: CMClient
    public let appID: UInt32
    public let destination: URL
    public var chunkConcurrency = 8
    public var onProgress: @Sendable (DownloadProgress) -> Void = { _ in }
    /// Received CDN chunk response-body bytes, before decrypt/decompress. May run concurrently.
    public var onTransfer: @Sendable (Int) -> Void = { _ in }

    public init(cm: CMClient, appID: UInt32, destination: URL) {
        self.cm = cm
        self.appID = appID
        self.destination = destination
    }

    /// Default games dir, mirroring fetch-depots.sh: $BIGSCREEN_GAMES_DIR,
    /// else the external disk, else ./games.
    public static func defaultGamesDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["BIGSCREEN_GAMES_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        let external = "/Volumes/VM/Big Screen/games"
        if FileManager.default.fileExists(atPath: external) {
            return URL(fileURLWithPath: external)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("games")
    }

    /// Resolve this once and persist the returned manifest to pin resume/repair to the same bytes.
    public func manifest(depot: DepotInfo, servers: [ContentServer]) async throws -> DepotManifest {
        guard let server = servers.first else { throw SteamError.download("no content servers available") }
        guard let gid = depot.manifestGID else {
            throw SteamError.download("depot \(depot.id) has no public manifest")
        }
        try Task.checkCancellation()
        let key = try await cm.depotKey(appID: appID, depotID: depot.id)
        let code = try await cm.manifestRequestCode(appID: appID, depotID: depot.id, manifestGID: gid)
        return try await CDNClient.fetchManifest(server: server, depotID: depot.id, gid: gid,
                                                  requestCode: code, depotKey: key)
    }

    /// Cache every selected key before a long transfer. Once prepared, pinned manifests
    /// download from the CDN without depending on the CM connection staying alive.
    public func prepare(manifests: [DepotManifest]) async throws {
        for depotID in Set(manifests.map(\.depotID)).sorted() {
            try Task.checkCancellation()
            _ = try await cm.depotKey(appID: appID, depotID: depotID)
        }
    }

    public func download(depot: DepotInfo, servers: [ContentServer]) async throws {
        try await download(manifest: manifest(depot: depot, servers: servers), servers: servers)
    }

    public func download(manifest: DepotManifest, servers: [ContentServer]) async throws {
        guard !servers.isEmpty else { throw SteamError.download("no content servers available") }
        try Task.checkCancellation()
        let key = try await cm.depotKey(appID: appID, depotID: manifest.depotID)
        var download = ResumableDepotDownload(destination: destination)
        download.chunkConcurrency = chunkConcurrency
        download.onProgress = onProgress
        try await download.download(manifest: manifest) { chunk in
            try await Self.fetchChunkWithRetry(servers: servers, depotID: manifest.depotID, chunk: chunk, key: key, onTransfer: onTransfer)
        }
    }

    static func fetchChunkWithRetry(servers: [ContentServer], depotID: UInt32,
                                    chunk: DepotManifest.Chunk, key: Data,
                                    onTransfer: @Sendable (Int) -> Void = { _ in }) async throws -> Data {
        guard !servers.isEmpty else { throw SteamError.download("no content servers available") }
        var lastError: Error = SteamError.download("no content servers available")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                return try await CDNClient.fetchChunk(server: servers[attempt % servers.count],
                    depotID: depotID, chunk: chunk, depotKey: key, onTransfer: onTransfer)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                lastError = error
                if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1))) }
            }
        }
        throw lastError
    }
}

/// Windows-and-english depot selection used by both `info` and `download`.
public func selectDepots(_ app: AppInfo, includeIDs: [UInt32] = []) -> (selected: [DepotInfo], skipped: [(DepotInfo, String)]) {
    var selected: [DepotInfo] = []
    var skipped: [(DepotInfo, String)] = []
    for depot in app.depots {
        if !includeIDs.isEmpty {
            if includeIDs.contains(depot.id) { selected.append(depot) } else { skipped.append((depot, "not requested")) }
            continue
        }
        if depot.manifestGID == nil { skipped.append((depot, "no public manifest")); continue }
        if depot.isSharedInstall { skipped.append((depot, "shared redistributable — runtime provides it")); continue }
        if !depot.isWindows { skipped.append((depot, "oslist=\(depot.osList)")); continue }
        if !depot.isEnglishOrAll { skipped.append((depot, "language=\(depot.language)")); continue }
        if depot.isDLC { skipped.append((depot, "DLC")); continue }
        selected.append(depot)
    }
    return (selected, skipped)
}
