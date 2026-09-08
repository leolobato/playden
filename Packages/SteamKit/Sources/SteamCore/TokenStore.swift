import Foundation

/// Persisted login state. PoC storage is a 0600 JSON file under
/// ~/Library/Application Support/Playden/; the final app should use the Keychain.
public struct StoredAuth: Codable, Sendable {
    public var accountName: String
    public var steamID: UInt64
    public var refreshToken: String
    public var accessToken: String?
    /// Steam Guard machine token (new_guard_data) — lets future password logins skip the code.
    public var guardData: String?
    public var cellID: UInt32?

    public init(accountName: String, steamID: UInt64, refreshToken: String,
                accessToken: String? = nil, guardData: String? = nil, cellID: UInt32? = nil) {
        self.accountName = accountName
        self.steamID = steamID
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.guardData = guardData
        self.cellID = cellID
    }
}

public enum TokenStore {
    public static var directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Playden")

    static var authFile: URL { directory.appendingPathComponent("auth.json") }
    static var depotKeysFile: URL { directory.appendingPathComponent("depot-keys.json") }

    public static func load() -> StoredAuth? {
        guard let data = try? Data(contentsOf: authFile) else { return nil }
        return try? JSONDecoder().decode(StoredAuth.self, from: data)
    }

    public static func save(_ auth: StoredAuth) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(auth)
        try data.write(to: authFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: authFile)
    }

    // MARK: depot key cache (keys never change per depot)

    public static func loadDepotKeys() -> [UInt32: Data] {
        guard let data = try? Data(contentsOf: depotKeysFile),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var out: [UInt32: Data] = [:]
        for (k, v) in dict {
            if let id = UInt32(k), let key = Data(hexString: v) { out[id] = key }
        }
        return out
    }

    public static func saveDepotKeys(_ keys: [UInt32: Data]) {
        let dict = Dictionary(uniqueKeysWithValues: keys.map { (String($0.key), $0.value.hexString) })
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: depotKeysFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: depotKeysFile.path)
        }
    }
}

/// Minimal JWT payload inspection (steamid + expiry) — Steam tokens are JWTs.
public enum JWT {
    public static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func steamID(_ token: String) -> UInt64? {
        guard let sub = payload(token)?["sub"] as? String else { return nil }
        return UInt64(sub)
    }

    public static func expiry(_ token: String) -> Date? {
        guard let exp = payload(token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// Applications inject their own credential boundary; the CLI keeps its existing file adapter.
public protocol AuthCredentialStore: Sendable {
    func load() throws -> StoredAuth?
    func save(_ auth: StoredAuth) throws
    func clear() throws
}
public struct FileAuthCredentialStore: AuthCredentialStore {
    public init() {}
    public func load() throws -> StoredAuth? { TokenStore.load() }
    public func save(_ auth: StoredAuth) throws { try TokenStore.save(auth) }
    public func clear() throws { TokenStore.clear() }
}
