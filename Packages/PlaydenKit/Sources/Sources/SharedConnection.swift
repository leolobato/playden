import Foundation

/// One logged-on connection shared by every concurrent operation for the same sign-in.
/// Steam allows a single CM session per login: each additional logon replaces the previous
/// session, which Steam logs off mid-request. Concurrent callers therefore share one client,
/// simultaneous first requests share one connection attempt, and the client closes after
/// it has been idle for `idleTimeout`.
actor SharedConnection<Key: Equatable & Sendable, Client: AnyObject & Sendable> {
    private let idleTimeout: Duration
    private let open: @Sendable (Key) async throws -> Client
    private let isAlive: @Sendable (Client) async -> Bool
    private let close: @Sendable (Client) async -> Void
    private var current: (key: Key, client: Client)?
    private var opening: (key: Key, id: UUID, task: Task<Client, Error>)?
    private var users = 0
    private var idleClose: Task<Void, Never>?

    init(idleTimeout: Duration, open: @escaping @Sendable (Key) async throws -> Client,
         isAlive: @escaping @Sendable (Client) async -> Bool, close: @escaping @Sendable (Client) async -> Void) {
        self.idleTimeout = idleTimeout; self.open = open; self.isAlive = isAlive; self.close = close
    }

    /// Runs `body` outside this actor so a long transfer never blocks other callers from connecting.
    nonisolated func use<T: Sendable>(_ key: Key, _ body: @Sendable (Client) async throws -> T) async throws -> T {
        let client = try await acquire(key)
        do {
            let value = try await body(client)
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    /// Closes the shared client, for example after sign-out or an account change.
    func reset() async {
        idleClose?.cancel(); idleClose = nil
        opening?.task.cancel(); opening = nil
        if let client = current?.client { current = nil; await close(client) }
    }

    private func acquire(_ key: Key) async throws -> Client {
        idleClose?.cancel(); idleClose = nil
        // Count the caller before any suspension so an idle close cannot fire while it waits.
        users += 1
        do {
            while true {
                if let existing = current {
                    if existing.key == key, await isAlive(existing.client) { return existing.client }
                    if current?.client === existing.client {
                        current = nil
                        await close(existing.client)
                    }
                    continue
                }
                let pending: (key: Key, id: UUID, task: Task<Client, Error>)
                if let existing = opening, existing.key == key { pending = existing }
                else {
                    opening?.task.cancel()
                    pending = (key, UUID(), Task { [open] in try await open(key) })
                    opening = pending
                }
                // Whichever waiter resumes first installs the client; a finished attempt is never awaited twice.
                do {
                    let client = try await pending.task.value
                    if opening?.id == pending.id { opening = nil; current = (key, client) }
                    // A stale attempt (the sign-in changed meanwhile) must not stay logged on:
                    // it would replace the current session. Closing is idempotent across waiters.
                    guard current?.client === client else { await close(client); continue }
                    return client
                } catch {
                    if opening?.id == pending.id { opening = nil }
                    throw error
                }
            }
        } catch {
            release()
            throw error
        }
    }

    private func release() {
        users = max(0, users - 1)
        guard users == 0, let client = current?.client else { return }
        idleClose?.cancel()
        idleClose = Task { [idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            await self.closeIfIdle(client)
        }
    }

    private func closeIfIdle(_ client: Client) async {
        guard users == 0, current?.client === client else { return }
        current = nil; idleClose = nil
        await close(client)
    }
}
