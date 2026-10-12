import Foundation

/// Known copy sizes and headroom on the filesystem that will receive them.
public enum InstallSpace {
    public static let headroom: Int64 = 256 * 1024 * 1024
    public static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
        let result = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !result.overflow else { throw failure("The storage requirement exceeds supported limits.") }
        return result.partialValue
    }
    public static func available(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        guard let free = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) else {
            throw failure("Free space on the runtime or temporary drive could not be checked.")
        }
        return max(0, free)
    }
    public static func require(_ bytes: Int64, at destination: URL,
                               capacity: (URL) throws -> Int64 = available) throws {
        var directory = destination
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" { directory.deleteLastPathComponent() }
        guard bytes >= 0, try capacity(directory) >= bytes else {
            throw failure("There is not enough free space on the runtime or temporary drive to continue.")
        }
    }
    /// Logical copy budget: HFS+ need not support clones. Links are not traversed.
    public static func copyBytes(in root: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var failure: Error?
        guard let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            failure = error; return false
        }) else { throw self.failure("The runtime copy size could not be checked.") }
        var bytes: Int64 = 0
        for case let file as URL in paths {
            try Task.checkCancellation()
            let value = try file.resourceValues(forKeys: keys)
            if value.isSymbolicLink == true { paths.skipDescendants(); continue }
            if value.isRegularFile == true { bytes = try add(bytes, Int64(value.fileSize ?? 0)) }
        }
        if let failure { throw failure }
        return bytes
    }
    private static func failure(_ reason: String) -> OperationFailure { .init(stage: "Reserve space", reason: reason, output: reason) }
}
