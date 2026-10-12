import XCTest
import CryptoKit
import zlib
import Darwin
@testable import SteamCore

final class DownloadResumeTests: XCTestCase {
    private let pieces = [Data("first".utf8), Data("second".utf8), Data("third".utf8)]
    private func fixture(path: String = "Game/data.bin", gid: UInt64 = 9, badHash: Bool = false) -> DepotManifest {
        var offset: UInt64 = 0
        let chunks = pieces.map { data -> DepotManifest.Chunk in
            defer { offset += UInt64(data.count) }
            return .init(sha: SteamCrypto.sha1(data), offset: offset, compressedSize: UInt32(data.count),
                         uncompressedSize: UInt32(data.count), checksum: DepotManifest.Chunk.adler(data))
        }
        let data = pieces.reduce(Data(), +)
        return .init(depotID: 7, gid: gid, files: [.init(path: path, size: UInt64(data.count), chunks: chunks,
                     contentSHA1: badHash ? Data(repeating: 0, count: 20) : SteamCrypto.sha1(data))], totalSize: UInt64(data.count))
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("download-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func download(_ root: URL) -> ResumableDepotDownload {
        var value = ResumableDepotDownload(destination: root); value.chunkConcurrency = 1; return value
    }
    private func partial(_ root: URL) throws -> URL {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        return try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "partial" })
    }
    private func receiptURL(_ root: URL, gid: UInt64 = 9) -> URL {
        root.appendingPathComponent(".gn-download/receipts/7-\(gid).json")
    }
    func testAllocationCreditCapsBlocksAndIgnoresInvalidAndUnrelatedFiles() async throws {
        let root = try root(), value = download(root), manifest = fixture()
        XCTAssertEqual(try value.allocatedContentBytes(in: manifest), 0)
        try Data(repeating: 9, count: 10000).write(to: root.appendingPathComponent("incidental"))
        try await value.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(try value.allocatedContentBytes(in: manifest), 16, "Small-file blocks cannot credit more than planned content")
        XCTAssertEqual(try value.allocatedContentBytes(in: manifest, includeCompleted: false), 0, "Repair budgets replacements even with matching receipts")
        try Data(repeating: 8, count: 16).write(to: root.appendingPathComponent("Game/data.bin"))
        XCTAssertEqual(try value.allocatedContentBytes(in: manifest), 0)
    }
    func testAllocationCreditRestoresOnlyValidJournalRanges() async throws {
        let root = try root(), manifest = fixture(), value = download(root)
        let feed = Feed(pieces, failAt: 5)
        do { try await value.download(manifest: manifest, fetchChunk: feed.fetch); XCTFail() } catch {}
        XCTAssertEqual(try value.allocatedContentBytes(in: manifest), 5)
        let partial = try partial(root)
        try Data(repeating: 0, count: 5).write(to: partial)
        XCTAssertEqual(try value.allocatedContentBytes(in: manifest), 0)
    }

    func testLiveAllocationCreditTracksPhysicalWritesIndependently() async throws {
        let root = try root(), samples = ProgressSamples()
        var value = download(root); value.onProgress = { samples.append($0) }
        try await value.download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(samples.values.last?.allocatedBytes, 16)
        XCTAssertTrue(samples.values.contains { $0.allocatedBytes == 5 })
    }
    func testRepairReplacementAllocationBoundsEightExistingTargets() throws {
        let root = try root(), files = (0..<20).map { index in
            DepotManifest.File(path: "file-\(index)", size: 16, chunks: fixture().files[0].chunks, contentSHA1: fixture().files[0].contentSHA1)
        }
        for file in files { try Data(repeating: 8, count: 16).write(to: root.appendingPathComponent(file.path)) }
        let manifest = DepotManifest(depotID: 7, gid: 9, files: files, totalSize: 320)
        let allocation = try download(root).replacementAllocation(in: manifest)
        XCTAssertEqual(allocation.missingBytes, 0)
        XCTAssertEqual(allocation.overlappingBytes.sorted(by: >).prefix(8).reduce(0, +), 128)
    }

    func testReservationPreflightsAndResumeVerifyRetainedChunksOnlyOnce() async throws {
        let root = try root(), manifest = fixture()
        do { try await download(root).download(manifest: manifest, fetchChunk: Feed(pieces, failAt: 5).fetch) } catch {}
        let diagnostics = SteamPerformanceDiagnostics()
        var resumed = ResumableDepotDownload(destination: root, diagnostics: diagnostics); resumed.chunkConcurrency = 1
        for _ in 0..<3 { XCTAssertEqual(try resumed.allocatedContentBytes(in: manifest), 5) }
        try await resumed.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 5, "Preflight and the production writer share only unchanged in-memory partial proof")
    }
    func testSparseCompleteFilesNeedNoWritesButSparsePartialsReceiveNoUnearnedCredit() throws {
        let root = try root(), data = Data(repeating: 0, count: 1024 * 1024)
        let file = DepotManifest.File(path: "sparse", size: UInt64(data.count), chunks: [
            .init(sha: SteamCrypto.sha1(data), offset: 0, compressedSize: 10, uncompressedSize: UInt32(data.count))], contentSHA1: SteamCrypto.sha1(data))
        let manifest = DepotManifest(depotID: 7, gid: 9, files: [file], totalSize: file.size)
        FileManager.default.createFile(atPath: root.appendingPathComponent("sparse").path, contents: nil)
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("sparse")); try handle.truncate(atOffset: file.size); try handle.close()
        XCTAssertEqual(try download(root).allocatedContentBytes(in: manifest), file.size)
        try FileManager.default.removeItem(at: root.appendingPathComponent("sparse"))
        let workspace = try DownloadWorkspace(destination: root, lock: false)
        let key = SHA256.hash(data: Data(file.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let base = ".gn-download/7/9/" + key
        let partial = try workspace.openFile(base + ".partial", flags: O_RDWR | O_CREAT, createParents: true)
        try partial.truncate(atOffset: file.size); try partial.close()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try workspace.writeAtomic(JSONSerialization.data(withJSONObject: ["version": 2,
            "fingerprint": Data(SHA256.hash(data: try encoder.encode(file))).base64EncodedString(), "completed": []]), path: base + ".json")
        XCTAssertEqual(try download(root).allocatedContentBytes(in: manifest), 0)
    }

    func testPartialProofIsConsumedByRestoreAndRejectsChangedJournalOrContent() async throws {
        let root = try root(), manifest = fixture()
        do { try await download(root).download(manifest: manifest, fetchChunk: Feed(pieces, failAt: 5).fetch) } catch {}
        let diagnostics = SteamPerformanceDiagnostics(), reader = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
        let partial = try partial(root), journal = partial.deletingPathExtension().appendingPathExtension("json")
        let originalJournal = try Data(contentsOf: journal)
        XCTAssertEqual(try reader.allocatedContentBytes(in: manifest), 5)
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: originalJournal) as? [String: Any]); changed["completed"] = []
        try JSONSerialization.data(withJSONObject: changed).write(to: journal)
        XCTAssertEqual(try reader.allocatedContentBytes(in: manifest), 0)
        try originalJournal.write(to: journal)
        let workspace = try DownloadWorkspace(destination: root, lock: false, diagnostics: diagnostics)
        let base = ".gn-download/7/9/" + partial.deletingPathExtension().lastPathComponent
        let writer = try ChunkCheckpointWriter(workspace: workspace, file: manifest.files[0], base: base)
        let firstRestore = try await writer.restore { _, _, _ in }; XCTAssertEqual(firstRestore.bytes, 5)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 5)
        let secondRestore = try await writer.restore { _, _, _ in }; XCTAssertEqual(secondRestore.bytes, 5)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 10, "A second resume cycle must verify unchanged chunks again")
        try Data("WRONG".utf8).write(to: partial)
        XCTAssertEqual(try reader.allocatedContentBytes(in: manifest), 0)
    }

    func testOlderCompletedAllocationBoundariesRefreshReceiptOnce() async throws {
        let root = try root(), manifest = fixture(path: "legitimate.orig")
        try pieces.reduce(Data(), +).write(to: root.appendingPathComponent("legitimate.orig"))
        let diagnostics = SteamPerformanceDiagnostics(), value = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
        for _ in 0..<3 { XCTAssertEqual(try value.allocatedContentBytes(in: manifest), 16) }
        try await value.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 16)
    }

    func testMatchingReceiptSkipsAllCompletedContentReads() async throws {
        let root = try root(), diagnostics = SteamPerformanceDiagnostics()
        let value = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
        try await value.download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
        try await value.download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL(root).path))
        XCTAssertTrue(try value.invalidFiles(in: fixture()).isEmpty)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 16, "Default full verification still reads content")
    }
    func testMissingReceiptVerifiesExactlyOnceThenReuses() async throws {
        let root = try root(), target = root.appendingPathComponent("Game/data.bin")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pieces.reduce(Data(), +).write(to: target)
        let diagnostics = SteamPerformanceDiagnostics(), feed = Feed(pieces)
        let value = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
        try await value.download(manifest: fixture(), fetchChunk: feed.fetch)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 16)
        try await value.download(manifest: fixture(), fetchChunk: feed.fetch)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 16)
        let fetched = await feed.requested; XCTAssertTrue(fetched.isEmpty)
    }
    func testInterruptionFlushesCompletedReceiptsAndSuccessCleansOldState() async throws {
        let root = try root(), first = fixture(path: "first"), second = fixture(path: "second")
        let manifest = DepotManifest(depotID: 7, gid: 9, files: first.files + second.files, totalSize: 32)
        let feed = InterruptSecondFileFeed(pieces: pieces)
        do { try await download(root).download(manifest: manifest, fetchChunk: feed.fetch); XCTFail() }
        catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL(root).path))
        let diagnostics = SteamPerformanceDiagnostics()
        try await ResumableDepotDownload(destination: root, diagnostics: diagnostics).download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 0)
        let files = FileManager.default.enumerator(at: root.appendingPathComponent(".gn-download"), includingPropertiesForKeys: nil)!
            .allObjects.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(files, ["7-9.json", "lock"])
    }
    func testSuccessfulNewGIDCleansObsoleteReceiptsAndPartialsOnly() async throws {
        let root = try root()
        try await download(root).download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
        let workspace = try DownloadWorkspace(destination: root, lock: false)
        try workspace.writeAtomic(Data("stale".utf8), path: ".gn-download/7/8/stale.partial")
        try workspace.writeAtomic(Data("other depot".utf8), path: ".gn-download/8/2/keep.partial")
        try workspace.writeAtomic(Data("other receipt".utf8), path: ".gn-download/receipts/8-2.json")
        try workspace.writeAtomic(Data("temp".utf8), path: ".gn-download/receipts/7-9.json.new-stale")
        let lockBefore = try workspace.metadata(".gn-download/lock")
        try await download(root).download(manifest: fixture(gid: 10), fetchChunk: Feed(pieces).fetch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL(root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gn-download/7").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gn-download/receipts/7-9.json.new-stale").path))
        XCTAssertEqual(try workspace.read(".gn-download/8/2/keep.partial"), Data("other depot".utf8))
        XCTAssertEqual(try workspace.read(".gn-download/receipts/8-2.json"), Data("other receipt".utf8))
        XCTAssertEqual(try workspace.metadata(".gn-download/lock"), lockBefore)
    }
    func testForcedSubsetPreservesUnrelatedPartialAndReceipt() async throws {
        let root = try root(), first = fixture(path: "first"), second = fixture(path: "second")
        let manifest = DepotManifest(depotID: 7, gid: 9, files: first.files + second.files, totalSize: 32)
        try await download(root).download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        let workspace = try DownloadWorkspace(destination: root, lock: false)
        try workspace.writeAtomic(Data("retained".utf8), path: ".gn-download/7/9/other.partial")
        var value = download(root); value.forceDownloadPaths = ["first"]
        try await value.download(manifest: first, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(try workspace.read(".gn-download/7/9/other.partial"), Data("retained".utf8))
        let diagnostics = SteamPerformanceDiagnostics()
        XCTAssertTrue(try ResumableDepotDownload(destination: root, diagnostics: diagnostics)
            .invalidFiles(in: second, mode: .receiptAssisted).isEmpty)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 0)
    }
    func testChangedMetadataReplacementAndCopiedReceiptFallBackOnce() async throws {
        for change in ["time", "size", "replacement", "copy", "version", "gid", "fingerprint"] {
            let root = try root(), target = root.appendingPathComponent("Game/data.bin")
            try await download(root).download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
            var manifest = fixture()
            switch change {
            case "time":
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: target.path)
            case "size": try Data("short".utf8).write(to: target)
            case "replacement": try pieces.reduce(Data(), +).write(to: target, options: .atomic)
            case "copy":
                let other = try self.root()
                try FileManager.default.copyItem(at: target, to: other.appendingPathComponent("copied"))
                try FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: other.appendingPathComponent("copied"), to: target)
            case "version", "gid":
                let url = receiptURL(root)
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                json[change] = 999
                try JSONSerialization.data(withJSONObject: json).write(to: url)
            default:
                let file = fixture().files[0]
                manifest = DepotManifest(depotID: 7, gid: 9, files: [.init(path: file.path, size: file.size,
                    flags: 32, chunks: file.chunks, contentSHA1: file.contentSHA1)], totalSize: 16)
            }
            let diagnostics = SteamPerformanceDiagnostics(), feed = Feed(pieces)
            let value = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
            try await value.download(manifest: manifest, fetchChunk: feed.fetch)
            XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, change == "size" ? 0 : 16, change)
            try await value.download(manifest: manifest, fetchChunk: feed.fetch)
            XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, change == "size" ? 0 : 16, change)
            XCTAssertEqual(try Data(contentsOf: target), pieces.reduce(Data(), +))
            let fetched = await feed.requested
            XCTAssertEqual(fetched.count, change == "size" ? 3 : 0, change)
        }
    }
    func testExcludedBackupPathsAlwaysHashButLegitimateOrigReusesReceipt() async throws {
        let root = try root(), manifest = fixture(path: "legitimate.orig")
        try await download(root).download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        let diagnostics = SteamPerformanceDiagnostics()
        var value = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
        XCTAssertTrue(try value.invalidFiles(in: manifest, mode: .receiptAssisted).isEmpty)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 0)
        value.receiptExcludedPaths = ["legitimate.orig"]
        for _ in 0..<2 { XCTAssertTrue(try value.invalidFiles(in: manifest, mode: .receiptAssisted).isEmpty) }
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 32)
        let saved = try JSONDecoder().decode(DownloadCompletionReceipt.self, from: Data(contentsOf: receiptURL(root)))
        XCTAssertNil(saved.entries["legitimate.orig"])
    }
    func testFallbackDoesNotCertifyReplacementOrMutationDuringHashing() async throws {
        for replace in [true, false] {
            let root = try root(), target = root.appendingPathComponent("Game/data.bin")
            try await download(root).download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
            try FileManager.default.removeItem(at: receiptURL(root))
            var mutated = false
            let invalid = try download(root).invalidFiles(in: fixture(), mode: .receiptAssisted) { _, checked, _ in
                if checked == 16 && !mutated {
                    mutated = true
                    if replace { try! Data(repeating: 88, count: 16).write(to: target, options: .atomic) }
                    else {
                        let handle = try! FileHandle(forWritingTo: target)
                        try! handle.write(contentsOf: Data(repeating: 88, count: 16)); try! handle.close()
                    }
                }
            }
            XCTAssertEqual(invalid, ["Game/data.bin"])
            XCTAssertEqual(try download(root).invalidFiles(in: fixture(), mode: .receiptAssisted), ["Game/data.bin"])
        }
    }
    func testCoarseTimestampModelDocumentsMetadataPreservingCorruptionAndFullDetection() async throws {
        let root = try root(), target = root.appendingPathComponent("Game/data.bin")
        try await download(root).download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
        // Model a filesystem that reports identical metadata for two same-tick writes. The
        // receipt retains the original manifest fingerprint while its observed metadata is
        // the shared value. Actual bytes and full verification use the real filesystem.
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data(repeating: 88, count: 16)); try handle.close()
        let workspace = try DownloadWorkspace(destination: root, lock: false)
        var receipt = try JSONDecoder().decode(DownloadCompletionReceipt.self, from: Data(contentsOf: receiptURL(root)))
        let original = try XCTUnwrap(receipt.entries["Game/data.bin"])
        receipt.entries["Game/data.bin"] = .init(fingerprint: original.fingerprint, metadata: try workspace.metadata("Game/data.bin"))
        try JSONEncoder().encode(receipt).write(to: receiptURL(root))
        let diagnostics = SteamPerformanceDiagnostics(), value = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
        XCTAssertTrue(try value.invalidFiles(in: fixture(), mode: .receiptAssisted).isEmpty)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 0)
        XCTAssertEqual(try value.invalidFiles(in: fixture()), ["Game/data.bin"])
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 16)
    }
    func testReceiptLookupRejectsHardLinksAndSymlinks() async throws {
        for symbolic in [false, true] {
            let root = try root(), target = root.appendingPathComponent("Game/data.bin"), outside = try self.root()
            try await download(root).download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
            let copy = outside.appendingPathComponent("copy")
            if symbolic {
                try FileManager.default.moveItem(at: target, to: copy)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: copy)
            } else { try FileManager.default.linkItem(at: target, to: copy) }
            XCTAssertEqual(try download(root).invalidFiles(in: fixture(), mode: .receiptAssisted), ["Game/data.bin"])
        }
    }
    func testReceiptCadenceUses128MiBOrFiveSecondsAndAtomicFlush() throws {
        let root = try root(), clock = ReceiptClock(), faults = PersistenceFaults()
        let workspace = try DownloadWorkspace(destination: root, beforePersistence: { try faults.visit($0) })
        let target = try workspace.openFile("file", flags: O_CREAT | O_RDWR)
        try target.truncate(atOffset: 1)
        let small = DepotManifest.File(path: "file", size: 1, chunks: [])
        let store = try DownloadCompletionReceipts(workspace: workspace, manifest: fixture(), now: { clock.now() })
        try store.record(small, path: "file", metadata: workspace.metadata(target))
        XCTAssertThrowsError(try workspace.read(".gn-download/receipts/7-9.json"))
        clock.advance(.seconds(4)); try store.checkpoint()
        XCTAssertThrowsError(try workspace.read(".gn-download/receipts/7-9.json"))
        clock.advance(.seconds(1)); try store.checkpoint()
        XCTAssertNoThrow(try workspace.read(".gn-download/receipts/7-9.json"))
        try store.record(small, path: "file", metadata: workspace.metadata(target))
        try store.checkpoint(processedBytes: 128 * 1024 * 1024 - 2)
        let writesBefore = faults.boundaries.count
        faults.arm(1)
        XCTAssertThrowsError(try store.checkpoint(processedBytes: 1), "128MiB forces a write even before five seconds")
        XCTAssertEqual(faults.boundaries.count, 1)
        XCTAssertEqual(writesBefore, 0)
        // An atomic write failure leaves the previous receipt decodable and dirty work retryable.
        XCTAssertNoThrow(try JSONDecoder().decode(DownloadCompletionReceipt.self, from: workspace.read(".gn-download/receipts/7-9.json")))
        try store.checkpoint(force: true)
        try target.close()
    }
    func testFullRefreshingReceiptsHashesOnceAndKeepsBackupsExcluded() async throws {
        let root = try root(), original = fixture(path: "original"), backup = fixture(path: "mapped.orig")
        let manifest = DepotManifest(depotID: 7, gid: 9, files: original.files + backup.files, totalSize: 32)
        try await download(root).download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        try FileManager.default.removeItem(at: receiptURL(root))
        let diagnostics = SteamPerformanceDiagnostics()
        var value = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
        value.receiptExcludedPaths = ["mapped.orig"]
        XCTAssertTrue(try value.invalidFiles(in: manifest, mode: .fullRefreshingReceipts).isEmpty)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 32)
        XCTAssertTrue(try value.invalidFiles(in: manifest, mode: .receiptAssisted).isEmpty)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 48, "Only mapped backup must be rehashed")
    }
    func testPendingReceiptFlushesDuringNextIncompleteFileTransfer() async throws {
        let root = try root(), first = fixture(path: "first"), second = fixture(path: "second")
        let manifest = DepotManifest(depotID: 7, gid: 9, files: first.files + second.files, totalSize: 32)
        let feed = ReceiptDuringTransferFeed(pieces: pieces, receipt: receiptURL(root))
        do { try await download(root).download(manifest: manifest, fetchChunk: feed.fetch); XCTFail() }
        catch is CancellationError {}
        let entries = await feed.entriesDuringTransfer
        XCTAssertEqual(entries, ["first"], "Previous file must checkpoint while second is still incomplete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("second").path))
    }
    func testCopiedReceiptInDifferentDestinationRequiresVerification() async throws {
        let root = try root(), copy = try self.root(), target = copy.appendingPathComponent("Game/data.bin")
        try await download(root).download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("Game/data.bin"), to: target)
        let workspace = try DownloadWorkspace(destination: copy, lock: false)
        try workspace.writeAtomic(Data(contentsOf: receiptURL(root)), path: ".gn-download/receipts/7-9.json")
        let diagnostics = SteamPerformanceDiagnostics()
        let value = ResumableDepotDownload(destination: copy, diagnostics: diagnostics)
        try await value.download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
        try await value.download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 16)
    }
    func testCleanupPreservesLeaseAndDoesNotFollowStateSymlink() throws {
        let root = try root(), outside = try self.root(), workspace = try DownloadWorkspace(destination: root)
        let sentinel = outside.appendingPathComponent("asset")
        try Data("keep".utf8).write(to: sentinel)
        try workspace.makeDirectory(".gn-download/7/9")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".gn-download/7/9/link"), withDestinationURL: outside)
        let lockBefore = try workspace.metadata(".gn-download/lock")
        try workspace.cleanCheckpoints(depotID: 7, keepingGID: 9)
        XCTAssertThrowsError(try DownloadWorkspace(destination: root))
        XCTAssertEqual(try workspace.metadata(".gn-download/lock"), lockBefore)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }
    func testTransferBytesAreNotCountedAgainWhenFileCompletes() throws {
        let root = try root(), workspace = try DownloadWorkspace(destination: root)
        let store = try DownloadCompletionReceipts(workspace: workspace, manifest: fixture())
        let first = try workspace.openFile("first", flags: O_CREAT | O_RDWR)
        try first.truncate(atOffset: 1)
        try store.record(.init(path: "first", size: 1, chunks: []), path: "first", metadata: workspace.metadata(first))
        let second = try workspace.openFile("second", flags: O_CREAT | O_RDWR)
        try second.truncate(atOffset: 64 * 1024 * 1024)
        try store.checkpoint(processedBytes: 64 * 1024 * 1024)
        try store.record(.init(path: "second", size: 64 * 1024 * 1024, chunks: []), path: "second",
            metadata: workspace.metadata(second), countVerifiedBytes: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL(root).path), "Only 64MiB + 1 byte has been processed")
        try store.checkpoint(processedBytes: 64 * 1024 * 1024 - 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL(root).path))
        try first.close(); try second.close()
    }
    func testLargeReceiptUsesFullPinnedContextForSubsetReads() async throws {
        let root = try root(), subset = fixture(), workspace = try DownloadWorkspace(destination: root, lock: false)
        try await download(root).download(manifest: subset, fetchChunk: Feed(pieces).fetch)
        var saved = try JSONDecoder().decode(DownloadCompletionReceipt.self, from: Data(contentsOf: receiptURL(root)))
        let entry = try XCTUnwrap(saved.entries["Game/data.bin"])
        var files = subset.files
        // Model a valid many-entry receipt without creating tens of thousands of game files.
        // Each entry has realistic metadata/fingerprint fields and a distinct legal relative path.
        for index in 0..<40_000 {
            let path = "assets/" + String(repeating: "a", count: 180) + "/\(index).bin"
            let file = DepotManifest.File(path: path, size: 16, chunks: subset.files[0].chunks, contentSHA1: subset.files[0].contentSHA1)
            files.append(file)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            saved.entries[path] = .init(fingerprint: Data(SHA256.hash(data: try encoder.encode(file))), metadata: entry.metadata)
        }
        let large = try JSONEncoder().encode(saved)
        XCTAssertGreaterThan(large.count, 16 * 1024 * 1024)
        try workspace.writeAtomic(large, path: ".gn-download/receipts/7-9.json")
        let full = DepotManifest(depotID: 7, gid: 9, files: files, totalSize: UInt64(files.count * 16))
        let fullStore = try DownloadCompletionReceipts(workspace: workspace, manifest: full)
        XCTAssertTrue(try fullStore.matches(subset.files[0], path: "Game/data.bin"), "A full operation sizes its own receipt without extra context")
        let diagnostics = SteamPerformanceDiagnostics()
        var value = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
        value.receiptManifest = full
        XCTAssertTrue(try value.invalidFiles(in: subset, mode: .receiptAssisted).isEmpty)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 0)
        let preserved = try JSONDecoder().decode(DownloadCompletionReceipt.self, from: Data(contentsOf: receiptURL(root)))
        XCTAssertEqual(preserved.entries.count, 40_001)
        // Sizing context cannot confer trust on a changed actual per-file manifest.
        XCTAssertEqual(try value.invalidFiles(in: fixture(badHash: true), mode: .receiptAssisted), ["Game/data.bin"])
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 16)
    }
    func testReceiptSizingContextMustMatchPinnedDepotAndGID() async throws {
        let root = try root()
        try await download(root).download(manifest: fixture(), fetchChunk: Feed(pieces).fetch)
        var value = download(root); value.receiptManifest = fixture(gid: 10)
        XCTAssertThrowsError(try value.invalidFiles(in: fixture(), mode: .receiptAssisted))
        value.receiptManifest = DepotManifest(depotID: 8, gid: 9, files: fixture().files, totalSize: 16)
        XCTAssertThrowsError(try value.invalidFiles(in: fixture(), mode: .receiptAssisted))
    }
    func testZlibZeroSeedMatchesKnownSteamVectorsIncludingEmpty() {
        // Independent literals: sums for abc are a=294, b=586; Python zlib.adler32(b"123456789", 0)=0x091501dd.
        for (data, expected): (Data, UInt32) in [(Data(), 0), (Data("abc".utf8), 0x024a0126),
                                               (Data("123456789".utf8), 0x091501dd)] {
            var nonNullByte: UInt8 = 0
            let actual = data.withUnsafeBytes { buffer in
                withUnsafePointer(to: &nonNullByte) { empty in
                    UInt32(zlib.adler32(0, buffer.bindMemory(to: UInt8.self).baseAddress ?? empty, uInt(buffer.count)))
                }
            }
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(DepotManifest.Chunk.adler(data), expected)
        }
        XCTAssertEqual(zlib.adler32(0, nil, 0), 1, "zlib's null-buffer initializer differs from Steam's empty zero-seed checksum")
    }
    private func journalURL(_ root: URL) throws -> URL { try partial(root).deletingPathExtension().appendingPathExtension("json") }
    func testInterruptedJournalStoresOnlyCompletedIndices() async throws {
        let root = try root()
        do { try await download(root).download(manifest: fixture(), fetchChunk: Feed(pieces, failAt: 11).fetch) }
        catch is CancellationError {}
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL(root))) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 2)
        XCTAssertEqual(saved["completed"] as? [Int], [0, 1])
    }
    func testVersionOneJournalKeepsValidIndicesAndRechecksCorruption() async throws {
        let root = try root()
        do { try await download(root).download(manifest: fixture(), fetchChunk: Feed(pieces, failAt: 11).fetch) }
        catch is CancellationError {}
        let url = try journalURL(root)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        saved["version"] = 1
        // Legacy hash values must not control retention; chunk.validate is authoritative.
        saved["completed"] = ["0": Data(repeating: 0, count: 32).base64EncodedString(),
                              "1": Data(SHA256.hash(data: pieces[1])).base64EncodedString()]
        try JSONSerialization.data(withJSONObject: saved).write(to: url)
        let handle = try FileHandle(forWritingTo: partial(root))
        try handle.seek(toOffset: 5); try handle.write(contentsOf: Data("WRONG!".utf8)); try handle.close()
        let resumed = Feed(pieces)
        try await download(root).download(manifest: fixture(), fetchChunk: resumed.fetch)
        let requested = await resumed.requested
        XCTAssertEqual(requested, [5, 11], "Keep usable legacy chunk 0 despite obsolete hash, refetch corrupt chunk 1")
    }
    func testChangedFileManifestAtSameGIDRejectsCheckpoint() async throws {
        let root = try root()
        do { try await download(root).download(manifest: fixture(), fetchChunk: Feed(pieces, failAt: 5).fetch) }
        catch is CancellationError {}
        let resumed = Feed(pieces)
        try await download(root).download(manifest: fixture(badHash: true), fetchChunk: resumed.fetch)
        let requested = await resumed.requested; XCTAssertEqual(requested, [0, 5, 11])
    }
    func testInvalidChunkRangesRejectedBeforeFetching() async throws {
        let root = try root(), source = fixture(), file = source.files[0], feed = Feed(pieces)
        for offset: UInt64 in [1, UInt64.max] {
            let first = file.chunks[0]
            let bad = DepotManifest.Chunk(sha: first.sha, offset: offset, compressedSize: first.compressedSize,
                uncompressedSize: first.uncompressedSize, checksum: first.checksum)
            let manifest = DepotManifest(depotID: 7, gid: 9, files: [.init(path: file.path, size: file.size,
                chunks: [bad] + file.chunks.dropFirst())], totalSize: file.size)
            do { try await download(root).download(manifest: manifest, fetchChunk: feed.fetch); XCTFail() } catch {}
        }
        let requested = await feed.requested; XCTAssertTrue(requested.isEmpty)
    }
    func testWriterRejectsIncomingLengthBeforeWriting() async throws {
        let root = try root()
        do { try await download(root).download(manifest: fixture()) { _ in Data("short".utf8).dropLast() }; XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: partial(root)).count, 0)
    }
    func testOriginalVerificationReportsAggregateBytesAndStillRejectsCorruption() async throws {
        let root = try root(), first = fixture(path: "first.bin"), second = fixture(path: "second.bin")
        let manifest = DepotManifest(depotID: 7, gid: 9, files: first.files + second.files, totalSize: 32)
        try await download(root).download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        var counts: [UInt64] = []
        let valid = try download(root).invalidFiles(in: manifest) { _, checked, total in
            counts.append(checked); XCTAssertEqual(total, 32)
        }
        XCTAssertTrue(valid.isEmpty)
        XCTAssertEqual(counts.first, 0); XCTAssertEqual(counts.last, 32)
        XCTAssertTrue(counts.contains(16)); XCTAssertEqual(counts, counts.sorted())
        try Data("bad".utf8).write(to: root.appendingPathComponent("second.bin"))
        let invalid = try download(root).invalidFiles(in: manifest) { _, checked, _ in counts.append(checked) }
        XCTAssertEqual(invalid, ["second.bin"])
        XCTAssertEqual(counts.last, 32, "100% examined must not imply every file was valid")
    }
    func testReopenReusesOnlyDurableVerifiedChunks() async throws {
        let root = try root(), manifest = fixture(), feed = Feed(pieces, failAt: 5)
        do { try await download(root).download(manifest: manifest, fetchChunk: feed.fetch); XCTFail("Expected interruption") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Game/data.bin").path))
        let resumed = Feed(pieces)
        try await download(root).download(manifest: manifest, fetchChunk: resumed.fetch)
        let requested = await resumed.requested
        XCTAssertEqual(requested, [5, 11])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Game/data.bin")), pieces.reduce(Data(), +))
        XCTAssertEqual(try download(root).invalidFiles(in: manifest), [])
    }
    func testLargeFileGrowsWithReceivedChunksAndShortPartialResumes() async throws {
        let root = try root()
        let data = Data(repeating: 7, count: 1024 * 1024), sha = SteamCrypto.sha1(data)
        let checksum = DepotManifest.Chunk.adler(data)
        let chunks = (0..<20_000).map { index in
            DepotManifest.Chunk(sha: sha, offset: UInt64(index) * UInt64(data.count), compressedSize: UInt32(data.count),
                uncompressedSize: UInt32(data.count), checksum: checksum)
        }
        let size = UInt64(chunks.count) * UInt64(data.count)
        let manifest = DepotManifest(depotID: 7, gid: 9, files: [.init(path: "Game/large.bdt", size: size, chunks: chunks)], totalSize: size)
        let feed = LargeFileFeed(root: root, data: data)
        do { try await download(root).download(manifest: manifest, fetchChunk: feed.fetch); XCTFail() }
        catch is CancellationError {}
        XCTAssertEqual(try partial(root).resourceValues(forKeys: [.fileSizeKey]).fileSize, data.count)
        let observations = await feed.partialSizes
        XCTAssertEqual(observations, [0, data.count], "Do not allocate the game's entire archive before fetching chunks")
        let resumed = LargeFileFeed(root: root, data: data)
        do { try await download(root).download(manifest: manifest, fetchChunk: resumed.fetch); XCTFail() }
        catch is CancellationError {}
        let offsets = await resumed.offsets
        XCTAssertEqual(offsets, [UInt64(data.count)], "A partial shorter than the final file must retain verified checkpoints")
    }
    func testOutOfOrderManifestFetchesFromStartWithoutChangingJournalIndices() async throws {
        let root = try root(), source = fixture(), file = source.files[0]
        let manifest = DepotManifest(depotID: source.depotID, gid: source.gid,
            files: [.init(path: file.path, size: file.size, chunks: file.chunks.reversed(), contentSHA1: file.contentSHA1)], totalSize: source.totalSize)
        let feed = Feed(pieces, failAt: 5)
        do { try await download(root).download(manifest: manifest, fetchChunk: feed.fetch) } catch {}
        let first = await feed.requested; XCTAssertEqual(first, [0, 5])
        let resumed = Feed(pieces)
        try await download(root).download(manifest: manifest, fetchChunk: resumed.fetch)
        let next = await resumed.requested; XCTAssertEqual(next, [5, 11])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file.path)), pieces.reduce(Data(), +))
    }
    func testTransferProgressExcludesRetainedChunksAndCompleteFiles() async throws {
        let root = try root(), manifest = fixture(), first = Feed(pieces, failAt: 5)
        do { try await download(root).download(manifest: manifest, fetchChunk: first.fetch) } catch {}
        let samples = ProgressSamples()
        var resumed = download(root); resumed.onProgress = samples.append
        try await resumed.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(samples.values.first(where: { $0.verification == nil })?.bytesDone, 5)
        XCTAssertEqual(samples.values.first?.bytesWritten, 0)
        XCTAssertEqual(samples.values.last?.bytesDone, 16)
        XCTAssertEqual(samples.values.last?.bytesWritten, 11)
        let cached = ProgressSamples()
        resumed.onProgress = cached.append
        try await resumed.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(cached.values.last?.bytesDone, 16)
        XCTAssertEqual(cached.values.last?.bytesWritten, 0)
    }
    func testFileVerificationReportsReadProgressWithoutAddingWrittenBytes() async throws {
        let root = try root(), manifest = fixture(), samples = ProgressSamples()
        var value = download(root); value.onProgress = samples.append
        try await value.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        let checks = samples.values.filter { $0.verification != nil }
        XCTAssertTrue(checks.isEmpty, "Fresh completion must not reread file content")
        XCTAssertNil(samples.values.last?.verification)
        // A complete file with a missing receipt reports fallback reads without a transfer.
        try FileManager.default.removeItem(at: receiptURL(root))
        let reused = ProgressSamples(); value.onProgress = reused.append
        try await value.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(reused.values.first?.verification?.bytesChecked, 0)
        XCTAssertEqual(reused.values.filter { $0.verification != nil }.last?.verification?.bytesChecked, manifest.totalSize)
        XCTAssertTrue(reused.values.allSatisfy { $0.bytesWritten == 0 })
        XCTAssertNil(reused.values.last?.verification)
    }
    func testResumeReportsSavedChunkChecksIncludingCorruptionBeforeFetching() async throws {
        let root = try root(), manifest = fixture(), initial = Feed(pieces, failAt: 11)
        do { try await download(root).download(manifest: manifest, fetchChunk: initial.fetch) } catch {}
        let handle = try FileHandle(forWritingTo: partial(root))
        try handle.write(contentsOf: Data("WRONG".utf8)); try handle.close()
        let samples = ProgressSamples()
        var resumed = download(root); resumed.onProgress = samples.append
        try await resumed.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        let checks = Array(samples.values.prefix { $0.verification != nil })
        XCTAssertEqual(checks.first?.verification?.bytesChecked, 0)
        XCTAssertEqual(checks.last?.verification?.bytesChecked, 11)
        XCTAssertTrue(checks.allSatisfy { $0.verification?.bytesTotal == 11 && $0.file == "Game/data.bin" })
        XCTAssertTrue(checks.allSatisfy { $0.bytesWritten == 0 })
        XCTAssertEqual(checks.last?.bytesDone, 6, "Corrupt saved chunks must not count as retained bytes")
        XCTAssertEqual(samples.values.first(where: { $0.verification == nil })?.bytesDone, 6)
        XCTAssertEqual(samples.values.last?.bytesWritten, 10)
        XCTAssertNil(samples.values.last?.verification)
    }
    func testCorruptRetainedChunkIsFetchedAgain() async throws {
        let root = try root(), manifest = fixture(), feed = Feed(pieces, failAt: 11)
        do { try await download(root).download(manifest: manifest, fetchChunk: feed.fetch) } catch {}
        let handle = try FileHandle(forWritingTo: partial(root))
        try handle.write(contentsOf: Data("WRONG".utf8)); try handle.close()
        let resumed = Feed(pieces)
        try await download(root).download(manifest: manifest, fetchChunk: resumed.fetch)
        let requested = await resumed.requested
        XCTAssertEqual(requested, [0, 11])
    }
    func testFailedReplacementPreservesOldFileAndRepairsSameSizeCorruption() async throws {
        let root = try root(), manifest = fixture(), target = root.appendingPathComponent("Game/data.bin")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = Data(repeating: 88, count: 16); try old.write(to: target)
        let failed = Feed(pieces, failAt: 5)
        do { try await download(root).download(manifest: manifest, fetchChunk: failed.fetch) } catch {}
        XCTAssertEqual(try Data(contentsOf: target), old)
        XCTAssertEqual(try download(root).invalidFiles(in: manifest), ["Game/data.bin"])
        try await download(root).download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(try Data(contentsOf: target), pieces.reduce(Data(), +))
    }
    func testPinnedManifestChangeDoesNotMixCheckpoints() async throws {
        let root = try root(), interrupted = Feed(pieces, failAt: 5)
        do { try await download(root).download(manifest: fixture(), fetchChunk: interrupted.fetch) } catch {}
        let resumed = Feed(pieces)
        try await download(root).download(manifest: fixture(gid: 10), fetchChunk: resumed.fetch)
        let requested = await resumed.requested
        XCTAssertEqual(requested, [0, 5, 11])
    }
    func testFreshCompletionTrustsChunksAndExplicitVerificationRejectsBadFileDigest() async throws {
        let root = try root(), manifest = fixture(badHash: true)
        let diagnostics = SteamPerformanceDiagnostics()
        let value = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
        try await value.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Game/data.bin")), Data("firstsecondthird".utf8))
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 0)
        XCTAssertEqual(diagnostics.snapshot()[.sha1].bytes, 0)
        XCTAssertEqual(try value.invalidFiles(in: manifest), ["Game/data.bin"])
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 16)
        XCTAssertEqual(diagnostics.snapshot()[.sha1].bytes, 16)
    }
    private func writer(_ workspace: DownloadWorkspace) throws -> ChunkCheckpointWriter {
        try ChunkCheckpointWriter(workspace: workspace, file: fixture().files[0], base: ".gn-download/test/file")
    }
    private func commitAll(_ writer: ChunkCheckpointWriter) async throws {
        for (index, data) in pieces.enumerated() { try await writer.commit(data, index: index) }
    }
    private func completed(_ workspace: DownloadWorkspace) throws -> [Int] {
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: workspace.read(".gn-download/test/file.json")) as? [String: Any])
        return try XCTUnwrap(saved["completed"] as? [Int])
    }
    func testFinishUsesOneFileSyncAndNeverWritesDisposableJournal() async throws {
        let root = try root(), diagnostics = SteamPerformanceDiagnostics()
        let workspace = try DownloadWorkspace(destination: root, diagnostics: diagnostics), value = try writer(workspace)
        try await commitAll(value)
        try await value.finish(to: "Game/data.bin")
        XCTAssertEqual(diagnostics.snapshot()[.fileSync].count, 1)
        XCTAssertEqual(diagnostics.snapshot()[.directorySync].count, 2)
        XCTAssertEqual(diagnostics.snapshot()[.checkpoint].count, 0)
        XCTAssertEqual(diagnostics.snapshot()[.fileWrite].bytes, 16)
        XCTAssertThrowsError(try workspace.read(".gn-download/test/file.json"))
    }
    func testAtomicJournalReplacementSyncsOneDirectory() throws {
        let root = try root(), diagnostics = SteamPerformanceDiagnostics()
        let workspace = try DownloadWorkspace(destination: root, diagnostics: diagnostics)
        try workspace.writeAtomic(Data("state".utf8), path: ".gn-download/test/state.json")
        XCTAssertEqual(diagnostics.snapshot()[.directorySync].count, 1)
        XCTAssertEqual(try workspace.read(".gn-download/test/state.json"), Data("state".utf8))
    }
    func testCheckpointByteThresholdIs128MiBAndFinalChunkDefersToFinish() async throws {
        let root = try root(), diagnostics = SteamPerformanceDiagnostics()
        let workspace = try DownloadWorkspace(destination: root, diagnostics: diagnostics)
        let data = Data(repeating: 7, count: 1024 * 1024)
        let chunks = (0..<129).map { index in
            DepotManifest.Chunk(sha: SteamCrypto.sha1(data), offset: UInt64(index * data.count),
                compressedSize: UInt32(data.count), uncompressedSize: UInt32(data.count), checksum: 0)
        }
        let file = DepotManifest.File(path: "large.bin", size: UInt64(129 * data.count), chunks: chunks)
        let value = try ChunkCheckpointWriter(workspace: workspace, file: file, base: ".gn-download/test/file")
        for index in 0..<127 { try await value.commit(data, index: index) }
        XCTAssertEqual(diagnostics.snapshot()[.checkpoint].count, 0)
        try await value.commit(data, index: 127)
        XCTAssertEqual(diagnostics.snapshot()[.checkpoint].count, 1)
        XCTAssertEqual(try completed(workspace), Array(0..<128))
        try await value.commit(data, index: 128)
        try await value.finish(to: "large.bin")
        XCTAssertEqual(diagnostics.snapshot()[.checkpoint].count, 1)
        XCTAssertEqual(diagnostics.snapshot()[.fileSync].count, 3)
        XCTAssertEqual(diagnostics.snapshot()[.directorySync].count, 3)
        let finalDiagnostics = SteamPerformanceDiagnostics()
        let finalWorkspace = try DownloadWorkspace(destination: root, lock: false, diagnostics: finalDiagnostics)
        let finalFile = DepotManifest.File(path: "exact.bin", size: UInt64(128 * data.count), chunks: Array(chunks.prefix(128)))
        let finalWriter = try ChunkCheckpointWriter(workspace: finalWorkspace, file: finalFile, base: ".gn-download/test/exact")
        for index in 0..<128 { try await finalWriter.commit(data, index: index) }
        try await finalWriter.finish(to: "exact.bin")
        XCTAssertEqual(finalDiagnostics.snapshot()[.checkpoint].count, 0, "Final threshold chunk uses publication durability")
        XCTAssertEqual(finalDiagnostics.snapshot()[.fileSync].count, 1)
    }
    func testCheckpointTimeThresholdIsFiveSeconds() async throws {
        let root = try root(), diagnostics = SteamPerformanceDiagnostics()
        let workspace = try DownloadWorkspace(destination: root, diagnostics: diagnostics), value = try writer(workspace)
        try await Task.sleep(for: .milliseconds(1100))
        try await value.commit(pieces[0], index: 0)
        XCTAssertEqual(diagnostics.snapshot()[.checkpoint].count, 0)
        try await Task.sleep(for: .seconds(4))
        try await value.commit(pieces[1], index: 1)
        XCTAssertEqual(diagnostics.snapshot()[.checkpoint].count, 1)
        XCTAssertEqual(try completed(workspace), [0, 1])
    }
    func testCancelledTaskCanCheckpointIncompleteWork() async throws {
        let root = try root(), workspace = try DownloadWorkspace(destination: root), value = try writer(workspace)
        try await value.commit(pieces[0], index: 0)
        try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await value.checkpoint()
        }.value
        let retry = try writer(DownloadWorkspace(destination: root, lock: false))
        let retained = try await retry.restore { _, _, _ in }
        XCTAssertEqual(retained.indices, [0]); XCTAssertEqual(retained.bytes, 5)
    }
    func testCheckpointFailuresBeforeAndAfterEveryBoundaryNeverRetainMissingBytes() async throws {
        // Five checkpoint boundaries, followed by another content write to fail after the final sync.
        for failure in 1...6 {
            let root = try root(), faults = PersistenceFaults()
            let workspace = try DownloadWorkspace(destination: root, beforePersistence: { try faults.visit($0) })
            let value = try writer(workspace)
            try await value.commit(pieces[0], index: 0)
            try await value.checkpoint()
            try await value.commit(pieces[1], index: 1)
            faults.arm(failure)
            do {
                try await value.checkpoint()
                try await value.commit(pieces[2], index: 2)
                XCTFail("Boundary \(failure) must fail")
            } catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
            XCTAssertEqual(try completed(workspace), failure >= 5 ? [0, 1] : [0])
            let boundaries = faults.boundaries
            XCTAssertEqual(boundaries.first, .fileSync)
            if failure >= 2 { XCTAssertEqual(boundaries[1], .write(".gn-download/test/file.json")) }
            if failure >= 3 { XCTAssertEqual(boundaries[2], .fileSync) }
            if failure >= 5 { XCTAssertEqual(boundaries[4], .directorySync) }
            // Simulate missing recent disk bytes, even if a journal was already renamed.
            let partial = try workspace.openFile(".gn-download/test/file.partial", flags: O_WRONLY)
            try partial.truncate(atOffset: 5); try partial.close()
            let retry = try writer(DownloadWorkspace(destination: root, lock: false))
            let retained = try await retry.restore { _, _, _ in }
            XCTAssertEqual(retained.indices, [0], "Boundary \(failure) cannot count missing chunk 1")
            XCTAssertEqual(retained.bytes, 5)
        }
    }
    func testPublicationFailuresKeepOldTargetOrCompleteValidatedNewTarget() async throws {
        for failure in 1...4 {
            let root = try root(), target = root.appendingPathComponent("Game/data.bin"), faults = PersistenceFaults()
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let old = Data("old target".utf8); try old.write(to: target)
            let workspace = try DownloadWorkspace(destination: root, beforePersistence: { try faults.visit($0) }), value = try writer(workspace)
            try await value.commit(pieces[0], index: 0)
            try await value.checkpoint()
            for index in 1...2 { try await value.commit(pieces[index], index: index) }
            faults.arm(failure)
            do { try await value.finish(to: "Game/data.bin"); XCTFail("Boundary \(failure) must fail") }
            catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
            XCTAssertEqual(try Data(contentsOf: target), failure <= 2 ? old : pieces.reduce(Data(), +))
            XCTAssertEqual(faults.boundaries.first, .fileSync)
            XCTAssertFalse(faults.boundaries.contains(.write(".gn-download/test/file.json")))
            let retry = try writer(DownloadWorkspace(destination: root, lock: false))
            let retained = try await retry.restore { _, _, _ in }
            XCTAssertEqual(retained.indices, failure <= 2 ? [0] : [])
            XCTAssertEqual(retained.bytes, failure <= 2 ? 5 : 0)
        }
    }
    func testFreshExecutablePublishesWithExecutablePermissions() async throws {
        let root = try root(), source = fixture(), file = source.files[0]
        let manifest = DepotManifest(depotID: 7, gid: 9, files: [.init(path: file.path, size: file.size,
            flags: 32, chunks: file.chunks, contentSHA1: file.contentSHA1)], totalSize: 16)
        try await download(root).download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file.path).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
    }
    func testCancelledFinishDoesNotPublishAndCheckpointRemainsUsable() async throws {
        let root = try root(), workspace = try DownloadWorkspace(destination: root), value = try writer(workspace)
        try await commitAll(value)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await value.finish(to: "Game/data.bin")
        }
        do { try await task.value; XCTFail("Already cancelled finish must stop") } catch is CancellationError {}
        try await value.checkpoint()
        XCTAssertEqual(try completed(workspace), [0, 1, 2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Game/data.bin").path))
    }
    func testFinishRejectsMissingChunkEvenWhenPartialHasExpectedSize() async throws {
        let root = try root(), workspace = try DownloadWorkspace(destination: root), value = try writer(workspace)
        try await value.commit(pieces[2], index: 2)
        do { try await value.finish(to: "Game/data.bin"); XCTFail("Missing chunks must not publish") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Game/data.bin").path))
        XCTAssertEqual(try completed(workspace), [])
    }
    func testFinishRejectsTruncatedFileWithEveryChunkCompleted() async throws {
        let root = try root(), workspace = try DownloadWorkspace(destination: root), value = try writer(workspace)
        try await commitAll(value)
        let handle = try workspace.openFile(".gn-download/test/file.partial", flags: O_WRONLY)
        try handle.truncate(atOffset: 15); try handle.close()
        do { try await value.finish(to: "Game/data.bin"); XCTFail("Short files must not publish") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Game/data.bin").path))
        XCTAssertEqual(try completed(workspace), [])
    }
    func testENOSPCWriteDoesNotMarkFailedChunkCompleted() async throws {
        let root = try root()
        let workspace = try DownloadWorkspace(destination: root, beforePersistence: { boundary in
            if boundary == .write(".gn-download/test/file.partial"),
               (try? root.appendingPathComponent(".gn-download/test/file.partial").resourceValues(forKeys: [.fileSizeKey]).fileSize) == 5 {
                throw POSIXError(.ENOSPC)
            }
        })
        let value = try writer(workspace)
        try await value.commit(pieces[0], index: 0)
        do { try await value.commit(pieces[1], index: 1); XCTFail("Expected ENOSPC") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .ENOSPC) }
        try await value.checkpoint()
        XCTAssertEqual(try completed(workspace), [0], "Failed chunk must not enter the durable journal")
        let retained = try await value.restore { _, _, _ in }
        XCTAssertEqual(retained.indices, [0])
        XCTAssertEqual(retained.bytes, 5)
        do { try await value.finish(to: "Game/data.bin"); XCTFail("Failed write must not publish") } catch {}
        XCTAssertEqual(try completed(workspace), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Game/data.bin").path))
    }
    func testFailedRenamePreservesOldTargetAndCheckpointForRetry() async throws {
        let root = try root(), target = root.appendingPathComponent("Game/data.bin")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old target".utf8).write(to: target)
        let workspace = try DownloadWorkspace(destination: root, beforePersistence: { boundary in
            if boundary == .rename(".gn-download/test/file.partial", "Game/data.bin") { throw POSIXError(.EIO) }
        })
        let value = try writer(workspace)
        try await commitAll(value)
        do { try await value.finish(to: "Game/data.bin"); XCTFail("Expected failed publication") }
        catch let error as POSIXError { XCTAssertEqual(error.code, .EIO) }
        XCTAssertEqual(try Data(contentsOf: target), Data("old target".utf8))
        // The download caller saves received work after publication failure.
        try await value.checkpoint()
        XCTAssertEqual(try completed(workspace), [0, 1, 2])
        let retryWorkspace = try DownloadWorkspace(destination: root, lock: false)
        let retry = try writer(retryWorkspace)
        let retained = try await retry.restore { _, _, _ in }
        XCTAssertEqual(retained.bytes, 16)
        try await retry.finish(to: "Game/data.bin")
        XCTAssertEqual(try Data(contentsOf: target), Data("firstsecondthird".utf8))
        XCTAssertThrowsError(try retryWorkspace.read(".gn-download/test/file.json"))
    }
    func testCancellationDuringFinalSyncKeepsCheckpointAndOldTarget() async throws {
        let root = try root(), target = root.appendingPathComponent("Game/data.bin")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old target".utf8).write(to: target)
        let workspace = try DownloadWorkspace(destination: root, beforePersistence: { boundary in
            if boundary == .fileSync { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let value = try writer(workspace)
        try await commitAll(value)
        try await Task { try await value.checkpoint() }.value
        let task = Task { try await value.finish(to: "Game/data.bin") }
        do { _ = try await task.value; XCTFail("Cancellation before publication must stop finish") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: target), Data("old target".utf8))
        XCTAssertEqual(try completed(workspace), [0, 1, 2])
    }
    func testCancellationAfterRenameCompletesPublicationAndJournalCleanup() async throws {
        let root = try root()
        let workspace = try DownloadWorkspace(destination: root, beforePersistence: { boundary in
            if boundary == .directorySync { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let value = try writer(workspace)
        try await commitAll(value)
        // Flush first so cancellation is injected in publication's directory sync.
        try await Task { try await value.checkpoint() }.value
        _ = try await Task { try await value.finish(to: "Game/data.bin") }.value
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Game/data.bin")), Data("firstsecondthird".utf8))
        XCTAssertThrowsError(try workspace.read(".gn-download/test/file.json"))
    }
    func testInvalidManifestPathsRejectedBeforeAnyFetch() async throws {
        let root = try root(), feed = Feed(pieces)
        for path in ["../escape", "Game/../../escape", "Game\\..\\escape", "/absolute", "C:\\escape", ".gn-download/lock"] {
            do { try await download(root).download(manifest: fixture(path: path), fetchChunk: feed.fetch); XCTFail(path) } catch {}
        }
        let requested = await feed.requested
        XCTAssertTrue(requested.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testExistingSymlinkParentCannotRedirectWrites() async throws {
        let root = try root(), outside = try self.root(), feed = Feed(pieces)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Game"), withDestinationURL: outside)
        do { try await download(root).download(manifest: fixture(), fetchChunk: feed.fetch); XCTFail() } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testExclusiveDestinationLeaseAndEmptyServerList() async throws {
        let root = try root(), lease = try DownloadWorkspace(destination: root)
        defer { withExtendedLifetime(lease) {} }
        do {
            XCTAssertThrowsError(try DownloadWorkspace(destination: root))
            do { _ = try await DownloadEngine.fetchChunkWithRetry(servers: [], depotID: 7,
                   chunk: fixture().files[0].chunks[0], key: Data()); XCTFail() } catch {}
        }
    }
    func testChecksumAndEmptyFile() async throws {
        let chunk = fixture().files[0].chunks[0]
        XCTAssertNoThrow(try chunk.validate(pieces[0]))
        XCTAssertThrowsError(try chunk.validate(Data("wrong".utf8)))
        XCTAssertEqual(DepotManifest.Chunk.adler(Data("abc".utf8)), 0x024a0126)
        let root = try root(), empty = DepotManifest(depotID: 7, gid: 9,
            files: [.init(path: "empty", size: 0, chunks: [], contentSHA1: SteamCrypto.sha1(Data()))], totalSize: 0)
        var value = download(root); value.chunkConcurrency = 0
        try await value.download(manifest: empty) { _ in XCTFail(); return Data() }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("empty")), Data())
    }
    func testEmptySteamPlaceholderWithZeroDigestDownloadsAndRepairs() async throws {
        let root = try root(), path = "Adobe AIR/Versions/1.0/Resources/AdobeCP.dll"
        let manifest = DepotManifest(depotID: 272041, gid: 6869307445582119673,
            files: [.init(path: path, size: 0, chunks: [], contentSHA1: Data(repeating: 0, count: 20))], totalSize: 0)
        let value = download(root)
        XCTAssertEqual(try value.invalidFiles(in: manifest), [path])
        try await value.download(manifest: manifest) { _ in XCTFail("Empty placeholders require no chunks"); return Data() }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data())
        XCTAssertTrue(try value.invalidFiles(in: manifest).isEmpty)
        try Data("unexpected bytes".utf8).write(to: root.appendingPathComponent(path))
        XCTAssertEqual(try value.invalidFiles(in: manifest), [path])
        try await value.download(manifest: manifest) { _ in XCTFail(); return Data() }
        XCTAssertTrue(try value.invalidFiles(in: manifest).isEmpty)
    }
}

private actor LargeFileFeed {
    let root: URL
    let data: Data
    var offsets: [UInt64] = []
    var partialSizes: [Int] = []
    init(root: URL, data: Data) { self.root = root; self.data = data }
    nonisolated var fetch: @Sendable (DepotManifest.Chunk) async throws -> Data {
        { chunk in try await self.read(chunk) }
    }
    func read(_ chunk: DepotManifest.Chunk) throws -> Data {
        offsets.append(chunk.offset)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])!
        let partial = try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "partial" })
        partialSizes.append(try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard chunk.offset == 0 else { throw CancellationError() }
        try chunk.validate(data)
        return data
    }
}

private actor Feed {
    let pieces: [Data]
    let failAt: UInt64?
    var requested: [UInt64] = []
    init(_ pieces: [Data], failAt: UInt64? = nil) { self.pieces = pieces; self.failAt = failAt }
    nonisolated var fetch: @Sendable (DepotManifest.Chunk) async throws -> Data {
        { chunk in try await self.read(chunk) }
    }
    func read(_ chunk: DepotManifest.Chunk) throws -> Data {
        requested.append(chunk.offset)
        if chunk.offset == failAt { throw CancellationError() }
        let data = pieces.first { SteamCrypto.sha1($0) == chunk.sha }!
        try chunk.validate(data)
        return data
    }
}

private final class ProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [DownloadProgress] = []
    func append(_ value: DownloadProgress) { lock.lock(); defer { lock.unlock() }; samples.append(value) }
    var values: [DownloadProgress] { lock.lock(); defer { lock.unlock() }; return samples }
}

private final class PersistenceFaults: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Int?
    private var visits: [DownloadWorkspace.PersistenceBoundary] = []
    func arm(_ failure: Int) { lock.lock(); defer { lock.unlock() }; self.failure = failure; visits = [] }
    func visit(_ boundary: DownloadWorkspace.PersistenceBoundary) throws {
        lock.lock(); defer { lock.unlock() }
        guard let failure else { return }
        visits.append(boundary)
        if visits.count == failure { throw POSIXError(.EIO) }
    }
    var boundaries: [DownloadWorkspace.PersistenceBoundary] { lock.lock(); defer { lock.unlock() }; return visits }
}

private actor InterruptSecondFileFeed {
    let pieces: [Data]
    var count = 0
    init(pieces: [Data]) { self.pieces = pieces }
    nonisolated var fetch: @Sendable (DepotManifest.Chunk) async throws -> Data {
        { chunk in try await self.read(chunk) }
    }
    func read(_ chunk: DepotManifest.Chunk) throws -> Data {
        count += 1
        if count > 3 { throw CancellationError() }
        return pieces.first { SteamCrypto.sha1($0) == chunk.sha }!
    }
}

private final class ReceiptClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

private actor ReceiptDuringTransferFeed {
    let pieces: [Data]
    let receipt: URL
    var count = 0
    var entriesDuringTransfer: [String] = []
    init(pieces: [Data], receipt: URL) { self.pieces = pieces; self.receipt = receipt }
    nonisolated var fetch: @Sendable (DepotManifest.Chunk) async throws -> Data {
        { chunk in try await self.read(chunk) }
    }
    func read(_ chunk: DepotManifest.Chunk) async throws -> Data {
        count += 1
        if count == 4 { try await Task.sleep(for: .milliseconds(5100)) }
        if count == 5 {
            let saved = try JSONDecoder().decode(DownloadCompletionReceipt.self, from: Data(contentsOf: receipt))
            entriesDuringTransfer = saved.entries.keys.sorted()
            throw CancellationError()
        }
        return pieces.first { SteamCrypto.sha1($0) == chunk.sha }!
    }
}
