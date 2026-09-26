import Foundation
import CryptoKit

/// The universal gbe_fork `libsteam_api.dylib` built by `scripts/build-gbe-macos.sh`.
public struct MacGBEAsset: Sendable {
    public static let sha256 = "756cd4f86ec030f4e66014a4dae35ff7ee60a8eaa500d18cd210c04d05950249"
    public let library: URL
    public init(library: URL) { self.library = library }
    public static func bundled() throws -> MacGBEAsset {
        guard let url = Bundle.module.url(forResource: "libsteam_api", withExtension: "dylib", subdirectory: "steampipe") else {
            throw SteamError.prepare("SteamCore is missing the bundled macOS gbe_fork library")
        }
        guard try digest(url) == sha256 else { throw SteamError.prepare("bundled macOS gbe_fork library hash mismatch") }
        return MacGBEAsset(library: url)
    }
    static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PreparedMacLibrary: Sendable {
    public let library: URL
    /// Where the original library now lives; outside any app bundle, so the bundle can be re-signed.
    public let original: URL
}

extension SteamPreparer {
    /// Replaces each `libsteam_api.dylib` in a macOS build with gbe_fork. Its settings go to
    /// `settingsRoot/steam_settings`, which the game must reach through `GseAppPath`, so writing
    /// settings never changes a signed app bundle. Originals move to `originals`, also outside
    /// the bundle. Emulator saves go to `savePath`, outside the game folder, so uninstalling
    /// never removes them.
    public func prepareMac(appID: UInt32, gameDirectory: URL, originals: URL, settingsRoot: URL, account: PrepareAccount,
                           metadata: PrepareMetadata, asset: MacGBEAsset, savePath: URL, offline: Bool = true) throws -> [PreparedMacLibrary] {
        let fm = FileManager.default
        let libraries = try files(in: gameDirectory, includingPackages: true) { $0 == "libsteam_api.dylib" }
            .filter { !$0.path.hasPrefix(originals.standardizedFileURL.path + "/") }
        let root = gameDirectory.standardizedFileURL.path + "/"
        let bundled = try MacGBEAsset.digest(asset.library)
        var prepared: [PreparedMacLibrary] = []
        for library in libraries {
            let path = library.standardizedFileURL.path
            guard path.hasPrefix(root) else { throw SteamError.prepare("\(library.path) leaves the game folder") }
            let relative = String(path.dropFirst(root.count))
            let original = originals.appendingPathComponent(relative)
            let hasOriginal = fm.fileExists(atPath: original.path)
            if try !hasOriginal && MacGBEAsset.digest(library) == bundled {
                throw SteamError.prepare("\(relative) is already gbe_fork but its original is missing")
            }
            let source = hasOriginal ? original : library
            guard Self.isMachO(source) else { throw SteamError.prepare("\(relative) is not a Mac library") }
            if !hasOriginal {
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: library, to: original)
            }
            try Data(contentsOf: asset.library).write(to: library, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path)
            prepared.append(PreparedMacLibrary(library: library, original: original))
        }
        guard let first = prepared.first else { return [] }
        // gbe_fork resolves steam_settings next to the directory GseAppPath names.
        let settingsLibrary = settingsRoot.appendingPathComponent("libsteam_api.dylib")
        try fm.createDirectory(at: settingsRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: savePath, withIntermediateDirectories: true)
        _ = try prepareInterfaces(from: first.original, beside: settingsLibrary)
        try writeSettings(appID: appID, beside: settingsLibrary, gameDirectory: gameDirectory, account: account,
                          metadata: metadata, offline: offline, localSavePath: savePath.path)
        return prepared
    }

    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        // Thin 32/64-bit Mach-O in either byte order, and universal (fat) files.
        let known: Set<[UInt8]> = [[0xCF, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF], [0xCE, 0xFA, 0xED, 0xFE],
                                   [0xFE, 0xED, 0xFA, 0xCE], [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA]]
        return known.contains(Array(magic))
    }
}
