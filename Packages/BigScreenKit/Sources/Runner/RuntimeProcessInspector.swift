import Foundation
import Darwin
import CoreGraphics
import Domain

public struct RuntimeObservation: Sendable {
    public let processes: [RuntimeProcess]
    public let windows: [GameWindow]
    /// A transient inspection failure is not evidence that a tracked process exited.
    public let unreadablePIDs: Set<Int32>
    public init(processes: [RuntimeProcess], windows: [GameWindow] = [], unreadablePIDs: Set<Int32> = []) {
        self.processes = processes; self.windows = windows; self.unreadablePIDs = unreadablePIDs
    }
}
public protocol RuntimeInspecting: Sendable {
    func inspect(bottle: URL) throws -> RuntimeObservation
    func identity(of pid: Int32) -> ProcessIdentity?
}
public struct RuntimeProcessInspector: RuntimeInspecting {
    public init() {}
    public func identity(of pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return .init(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
    public func inspect(bottle: URL) throws -> RuntimeObservation {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { throw POSIXError(.EIO) }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 256)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0, count < pids.count else { throw POSIXError(.EAGAIN) }
        var processes: [RuntimeProcess] = [], unreadable = Set<Int32>()
        let prefix = bottle.resolvingSymlinksInPath().path
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
                if kill(pid, 0) == 0 || errno == EPERM { unreadable.insert(pid) }
                continue
            }
            guard info.pbi_uid == getuid() else { continue }
            let identity = ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
            var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { unreadable.insert(pid); continue }
            let executable = String(cString: path)
            guard executable.lowercased().hasSuffix(".exe") || executable.hasSuffix("/wineserver") || executable.hasSuffix("/wine") else { continue }
            guard let arguments = Self.arguments(pid) else { unreadable.insert(pid); continue }
            guard let value = arguments.environment["WINEPREFIX"], URL(fileURLWithPath: value).resolvingSymlinksInPath().path == prefix else { continue }
            guard self.identity(of: pid) == identity else { continue }
            processes.append(.init(identity: identity, kind: Self.kind(arguments.argv.first ?? executable), executable: arguments.argv.first ?? executable))
        }
        // A game created while the launcher occupies a fullscreen Space can initially be in
        // another Space. It still needs to trigger handoff, otherwise both windows wait forever.
        let values = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return .init(processes: processes, windows: Self.windows(values, processes: processes), unreadablePIDs: unreadable)
    }
    static func windows(_ values: [[String: Any]], processes: [RuntimeProcess]) -> [GameWindow] {
        let games = Dictionary(uniqueKeysWithValues: processes.filter { $0.kind == .game }.map { ($0.identity.pid, $0.identity) })
        func area(_ value: [String: Any]) -> Double {
            let bounds = value[kCGWindowBounds as String] as? [String: Double] ?? [:]
            return bounds["Width", default: 0] * bounds["Height", default: 0]
        }
        return values.sorted {
            let left = $0[kCGWindowIsOnscreen as String] as? Bool == true
            let right = $1[kCGWindowIsOnscreen as String] as? Bool == true
            return left == right ? area($0) > area($1) : left
        }.compactMap { value -> GameWindow? in
            guard let pid = value[kCGWindowOwnerPID as String] as? Int32, let identity = games[pid],
                  let id = value[kCGWindowNumber as String] as? UInt32, (value[kCGWindowLayer as String] as? Int ?? -1) >= 0,
                  let bounds = value[kCGWindowBounds as String] as? [String: Double], bounds["Width", default: 0] >= 64, bounds["Height", default: 0] >= 64 else { return nil }
            return .init(id: id, process: identity)
        }
    }
    static func kind(_ argv0: String) -> RuntimeProcessKind {
        let path = argv0.replacingOccurrences(of: "\\", with: "/").lowercased()
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if name == "wineserver" { return .server }
        if name == "winewrapper.exe" || name == "wine" || name == "wine64" { return .wrapper }
        let services: Set<String> = ["services.exe", "winedevice.exe", "svchost.exe", "plugplay.exe", "rpcss.exe", "explorer.exe", "conhost.exe", "winemenubuilder.exe", "wineboot.exe", "rundll32.exe"]
        if path.hasPrefix("c:/windows/"), services.contains(name) { return .service }
        return .game
    }
    struct Arguments { let argv: [String]; let environment: [String: String] }
    private static func arguments(_ pid: Int32) -> Arguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= 4, size <= 2 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return decodeArguments(Array(bytes.prefix(size)))
    }
    static func decodeArguments(_ bytes: [UInt8]) -> Arguments? {
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return nil }
        var offset = 4
        while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
        guard offset < bytes.count else { return nil }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        var argv: [String] = []
        for _ in 0..<argc {
            let start = offset
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count else { return nil }
            argv.append(String(decoding: bytes[start..<offset], as: UTF8.self)); offset += 1
        }
        // Retain only the one identity field needed for attribution, never other process secrets.
        var environment: [String: String] = [:]
        for raw in bytes[offset...].split(separator: 0) {
            let value = String(decoding: raw, as: UTF8.self)
            if value.hasPrefix("WINEPREFIX=") { environment["WINEPREFIX"] = String(value.dropFirst(11)) }
        }
        return .init(argv: argv, environment: environment)
    }
}
