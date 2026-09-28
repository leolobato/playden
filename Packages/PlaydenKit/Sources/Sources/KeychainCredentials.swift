import Foundation
import Security
import OSLog
import SteamCore

struct KeychainFailure: Error {
    let status: OSStatus
    init(status: OSStatus) {
        self.status = status
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "org.lobato.playden", category: "Keychain").error("Credential storage failed: OSStatus \(status, privacy: .public)")
    }
}
/// One device-local account; service/account keys contain no player identity. Never falls back to a file.
struct KeychainCredentials: AuthCredentialStore {
    let item: KeychainItem<StoredAuth>
    init(service: String? = nil) { item = KeychainItem(service: service ?? KeychainItem<StoredAuth>.service("steam")) }
    func load() throws -> StoredAuth? { try item.load() }
    func save(_ auth: StoredAuth) throws { try item.save(auth) }
    func clear() throws { try item.clear() }
}
/// One Codable value in the login Keychain, readable only on this Mac after first unlock.
struct KeychainItem<Value: Codable> {
    let service: String
    static func service(_ store: String) -> String { "\(Bundle.main.bundleIdentifier ?? "org.lobato.playden").\(store)" }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "current", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> Value? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data = result as? Data else { throw KeychainFailure(status: errSecDecode) }
        return try JSONDecoder().decode(Value.self, from: data)
    }
    func save(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
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
