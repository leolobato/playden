import Foundation
import CoreGraphics
import ColorSync
import Darwin

/// Shared with the native helper. Only displays owned by this lease are restored.
@MainActor public final class ImmersiveDisplayConfiguration {
    public struct Change: Equatable {
        public let id: UInt32
        public let enabled: Bool
        public let origin: CGPoint?
        public init(id: UInt32, enabled: Bool, origin: CGPoint? = nil) {
            self.id = id; self.enabled = enabled; self.origin = origin
        }
    }
    private let targetUUID: String
    private let online: () throws -> [PrimaryDisplayScreen]
    private let allDisplays: () throws -> [String: UInt32]
    private let configure: ([Change]) throws -> Void
    private var original: [String: PrimaryDisplayScreen] = [:]

    public init(targetUUID: String, online: @escaping () throws -> [PrimaryDisplayScreen],
                allDisplays: @escaping () throws -> [String: UInt32],
                configure: @escaping ([Change]) throws -> Void) {
        self.targetUUID = targetUUID.lowercased()
        self.online = online; self.allDisplays = allDisplays; self.configure = configure
    }

    /// Called on entry and after topology changes / wake. Never disable the last display.
    public func enforce() throws {
        let screens = try online()
        guard let target = screens.first(where: { $0.uuid.lowercased() == targetUUID }) else {
            throw PrimaryDisplayError.unavailable
        }
        guard !screens.contains(where: \.isMirrored) else { throw PrimaryDisplayError.mirrored }
        for screen in screens where original[screen.uuid.lowercased()] == nil {
            original[screen.uuid.lowercased()] = screen
        }
        let others = screens.filter { $0.id != target.id }
        guard !others.isEmpty else { return }
        // Retain the snapshot even if commit fails: WindowServer may have partially applied it.
        try configure([Change(id: target.id, enabled: true, origin: .zero)] +
                      others.map { Change(id: $0.id, enabled: false) })
    }

    static func offlineKey(_ id: UInt32) -> String { "offline:\(id)" }

    public func restore() throws {
        guard !original.isEmpty else { return }
        // Disabled displays lose their UUID as well as disappearing from the online list.
        // Prefer a resolved UUID; use the captured ID only for a SkyLight entry that has
        // no UUID. Never use that fallback for an ID now identifying a different monitor.
        let ids = try allDisplays()
        let changes = original.values.sorted { ($0.isMain ? 0 : 1, $0.id) < ($1.isMain ? 0 : 1, $1.id) }
            .compactMap { screen -> Change? in
                guard let id = ids[screen.uuid.lowercased()] ?? ids[Self.offlineKey(screen.id)] else { return nil }
                return Change(id: id, enabled: true, origin: CGPoint(x: Int(screen.x), y: Int(screen.y)))
            }
        if !changes.isEmpty { try configure(changes) }
        original.removeAll()
    }
}

/// Dynamically resolved: an unavailable private API produces an error, never black panels.
@MainActor public final class SkyLightDisplayConfiguration {
    private typealias Enable = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
    private typealias List = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>) -> CGError
    private let handle: UnsafeMutableRawPointer
    private let enable: Enable
    private let list: List

    public init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            throw CocoaError(.featureUnsupported)
        }
        guard let enable = dlsym(handle, "SLSConfigureDisplayEnabled"), let list = dlsym(handle, "SLSGetDisplayList") else {
            dlclose(handle)
            throw CocoaError(.featureUnsupported)
        }
        self.handle = handle
        self.enable = unsafeBitCast(enable, to: Enable.self)
        self.list = unsafeBitCast(list, to: List.self)
    }

    public func displays() throws -> [String: UInt32] {
        var ids = [UInt32](repeating: 0, count: 128), count: UInt32 = 0
        let error = list(UInt32(ids.count), &ids, &count)
        guard error == .success, count < ids.count else { throw PrimaryDisplayError.invalidLayout }
        var result: [String: UInt32] = [:]
        for id in ids.prefix(Int(count)) {
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                result[(CFUUIDCreateString(nil, uuid) as String).lowercased()] = id
            } else {
                result[ImmersiveDisplayConfiguration.offlineKey(id)] = id
            }
        }
        return result
    }

    private func configurationError(_ operation: String, _ error: CGError) -> NSError {
        NSError(domain: "Playden.DisplayConfiguration", code: Int(error.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (Core Graphics error \(error.rawValue))."])
    }

    public func configure(_ changes: [ImmersiveDisplayConfiguration.Change]) throws {
        // Match the private API's single-display transaction pattern. Mixing enable
        // and origin flags, or restoring several disconnected displays at once, can
        // be rejected by WindowServer with illegalArgument (1001).
        let toggles = changes.filter { (CGDisplayIsOnline($0.id) != 0) != $0.enabled }
            .sorted { (CGDisplayIsBuiltin($0.id) != 0 ? 0 : 1, $0.id) <
                      (CGDisplayIsBuiltin($1.id) != 0 ? 0 : 1, $1.id) }
        var failure: Error?
        for change in toggles {
            do {
                try transaction {
                    let error = enable($0, change.id, change.enabled)
                    guard error == .success else { throw configurationError("Set display \(change.id) enabled=\(change.enabled)", error) }
                }
            } catch {
                // One unplugged display must not prevent recovery of the others.
                failure = error
            }
        }
        let origins = changes.filter { $0.origin != nil && CGDisplayIsOnline($0.id) != 0 }
        if !origins.isEmpty {
            try transaction { configuration in
                for change in origins {
                    guard let origin = change.origin else { continue }
                    let error = CGConfigureDisplayOrigin(configuration, change.id, Int32(origin.x), Int32(origin.y))
                    guard error == .success else { throw configurationError("Set display \(change.id) origin", error) }
                }
            }
        }
        if let failure { throw failure }
    }

    private func transaction(_ apply: (CGDisplayConfigRef) throws -> Void) throws {
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else { throw configurationError("Begin display configuration", begin) }
        do { try apply(configuration) }
        catch { CGCancelDisplayConfiguration(configuration); throw error }
        let error = CGCompleteDisplayConfiguration(configuration, .permanently)
        guard error == .success else { throw configurationError("Commit display configuration", error) }
    }
}
