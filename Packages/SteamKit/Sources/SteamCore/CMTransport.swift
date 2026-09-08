import Foundation

protocol CMTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

final class WebSocketCMTransport: CMTransport, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    init(url: URL, timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 32 * 1024 * 1024
        task.resume()
    }
    func send(_ data: Data) async throws { try await task.send(.data(data)) }
    func receive() async throws -> Data {
        while true {
            try Task.checkCancellation()
            if case .data(let data) = try await task.receive() { return data }
        }
    }
    func close() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    deinit { close() }
}

public protocol DepotKeyStore: Sendable {
    func load(_ depotID: UInt32) -> Data?
    func save(_ key: Data, for depotID: UInt32)
}
/// CLI compatibility adapter. The native app supplies MemoryDepotKeys instead.
public struct FileDepotKeys: DepotKeyStore {
    public init() {}
    public func load(_ depotID: UInt32) -> Data? { TokenStore.loadDepotKeys()[depotID] }
    public func save(_ key: Data, for depotID: UInt32) {
        var keys = TokenStore.loadDepotKeys(); keys[depotID] = key; TokenStore.saveDepotKeys(keys)
    }
}
public final class MemoryDepotKeys: DepotKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UInt32: Data] = [:]
    public init() {}
    public func load(_ depotID: UInt32) -> Data? { lock.withLock { keys[depotID] } }
    public func save(_ key: Data, for depotID: UInt32) { lock.withLock { keys[depotID] = key } }
}
