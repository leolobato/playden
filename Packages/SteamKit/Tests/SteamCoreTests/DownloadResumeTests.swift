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
        // A complete file reused on a later invocation also reports the disk read, without a transfer.
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
            let workspace = try DownloadWorkspace(destination: root, beforePersistence: faults.visit)
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
            let workspace = try DownloadWorkspace(destination: root, beforePersistence: faults.visit), value = try writer(workspace)
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
        do { try await task.value; XCTFail("Cancellation before publication must stop finish") } catch is CancellationError {}
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
        try await Task { try await value.finish(to: "Game/data.bin") }.value
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
