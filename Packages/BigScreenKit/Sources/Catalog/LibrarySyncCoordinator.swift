import Foundation
import Domain

public struct LibrarySyncResult: Sendable, Equatable {
    public var ownedCount: Int
    public var metadataUpdated: Int
    public var metadataFailed: Int
}
/// Commits the owned list before optional metadata so the library appears progressively.
/// UI observation never owns downloads or authentication; refresh cancellation only stops this sync.
public actor LibrarySyncCoordinator {
    private let catalog: CatalogStore
    private var revision = 0
    private let metadataDelay: Duration
    public init(catalog: CatalogStore, metadataDelay: Duration = .milliseconds(1500)) {
        self.catalog = catalog; self.metadataDelay = metadataDelay
    }
    public func cancel() { revision += 1 }
    public func refresh(source: any GameSource, onUpdate: @escaping @Sendable () -> Void = {}) async throws -> LibrarySyncResult {
        revision += 1; let run = revision
        let owned = try await source.ownedGames()
        try check(run)
        try catalog.replaceSourceCatalog(source: source.id, games: owned)
        try catalog.invalidateDownloadSizes(source: source.id)
        onUpdate()
        let cutoff = Date.now.addingTimeInterval(-6 * 3600)
        let ownedIDs = Set(owned.map(\.id))
        let pending = try catalog.snapshot().entries.filter {
            $0.id.source == source.id && ($0.source.metadataUpdatedAt ?? .distantPast) < cutoff && ownedIDs.contains($0.id)
        }.map(\.source)
        var result = LibrarySyncResult(ownedCount: owned.count, metadataUpdated: 0, metadataFailed: 0)
        try await withThrowingTaskGroup(of: (GameID, Result<SourceGameRecord, Error>).self) { group in
            var iterator = pending.makeIterator()
            func enqueue(_ record: SourceGameRecord) {
                let delay = metadataDelay
                group.addTask {
                    do {
                        try await Task.sleep(for: delay)
                        return (record.id, .success(try await source.metadata(for: record)))
                    } catch { return (record.id, .failure(error)) }
                }
            }
            for _ in 0..<2 { if let record = iterator.next() { enqueue(record) } }
            while let (id, response) = try await group.next() {
                do { try check(run) } catch { group.cancelAll(); throw error }
                switch response {
                case .success(let record):
                    guard record.id == id else { result.metadataFailed += 1; break }
                    if try catalog.updateMetadata(record) { result.metadataUpdated += 1; onUpdate() }
                case .failure(let error):
                    result.metadataFailed += 1
                    if let sourceError = error as? SourceFailure, [.network, .throttled, .expired].contains(sourceError) {
                        group.cancelAll(); return
                    }
                }
                if let record = iterator.next() { enqueue(record) }
            }
        }
        return result
    }
    private func check(_ run: Int) throws {
        try Task.checkCancellation()
        guard revision == run else { throw CancellationError() }
    }
}
