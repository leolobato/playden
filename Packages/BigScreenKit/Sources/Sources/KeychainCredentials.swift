import Foundation
import Security
import OSLog
import SteamCore

struct KeychainFailure: Error {
    let status: OSStatus
    init(status: OSStatus) {
        self.status = status
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bigscreen.app", category: "Keychain").error("Credential storage failed: OSStatus \(status, privacy: .public)")
    }
}
/// One device-local account; service/account keys contain no player identity. Never falls back to a file.
struct KeychainCredentials: AuthCredentialStore {
    let service: String
    private let legacyService: String?
    init(service: String? = nil, legacyService: String? = nil) {
        self.service = service ?? "\(Bundle.main.bundleIdentifier ?? "com.bigscreen.app").steam"
        // Only the default app identity imports the research build's credentials.
        // Custom bundle IDs have their own sign-in; explicit test services never touch user data.
        self.legacyService = legacyService ?? (service == nil && self.service == "com.bigscreen.app.steam"
            ? "com.gamenative.bigscreen.steam" : nil)
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "current", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> StoredAuth? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            guard let legacyService, legacyService != service else { return nil }
            let legacy = KeychainCredentials(service: legacyService)
            guard let auth = try legacy.load() else { return nil }
            try save(auth)
            try legacy.clear()
            return auth
        }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data = result as? Data else { throw KeychainFailure(status: errSecDecode) }
        return try JSONDecoder().decode(StoredAuth.self, from: data)
    }
    func save(_ auth: StoredAuth) throws {
        let data = try JSONEncoder().encode(auth)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }
    func clear() throws {
        // Clear the legacy record first so sign-out cannot resurrect it on the next load.
        if let legacyService, legacyService != service { try KeychainCredentials(service: legacyService).clear() }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }
}
final class MemoryCredentials: AuthCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredAuth?
    func load() throws -> StoredAuth? { lock.withLock { value } }
    func save(_ auth: StoredAuth) throws { lock.withLock { value = auth } }
    func clear() throws { lock.withLock { value = nil } }
}
