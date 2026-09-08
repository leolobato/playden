import Foundation
import SteamProto

public struct SteamEntitlements: Equatable, Sendable {
    public let appIDs: Set<UInt32>
    public let depotIDs: Set<UInt32>
    /// Earliest acquisition among this account's active licenses that include each app.
    public let appAcquiredAt: [UInt32: Date]
    public init(appIDs: Set<UInt32>, depotIDs: Set<UInt32>, appAcquiredAt: [UInt32: Date] = [:]) {
        self.appIDs = appIDs; self.depotIDs = depotIDs; self.appAcquiredAt = appAcquiredAt
    }
}
public extension CMClient {
    /// Only active licenses belonging to this account contribute ownership. PICS listing an app's
    /// possible DLC is not ownership evidence. No package tokens or account identity leave this method.
    func ownedEntitlements() async throws -> SteamEntitlements {
        try await waitForLicenses()
        let accountID = UInt32(truncatingIfNeeded: steamID)
        let active = licenses.filter { Self.isOwnedActiveLicense($0, accountID: accountID) }
        var packages: [UInt32: UInt64] = [:]
        for license in active { packages[license.packageID] = license.accessToken }
        let ids = packages.keys.sorted()
        var apps = Set<UInt32>(), depots = Set<UInt32>()
        var packageApps: [UInt32: Set<UInt32>] = [:]
        for start in stride(from: 0, to: ids.count, by: 50) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            var request = CMsgClientPICSProductInfoRequest()
            request.packages = batch.map { id in
                var package = CMsgClientPICSProductInfoRequest.PackageInfo()
                package.packageid = id; package.accessToken = packages[id] ?? 0; return package
            }
            let parts = try await jobRequest(.kEmsgClientPicsproductInfoRequest, body: request) { data in
                (try? CMsgClientPICSProductInfoResponse(serializedBytes: data).responsePending) != true
            }
            var received = Set<UInt32>()
            for part in parts {
                let response = try CMsgClientPICSProductInfoResponse(serializedBytes: part)
                for package in response.packages where batch.contains(package.packageid) {
                    guard !package.missingToken else { throw SteamError.protocolError("PICS package access was denied") }
                    let content = try Self.packageEntitlements(package.buffer, packageID: package.packageid)
                    apps.formUnion(content.appIDs); depots.formUnion(content.depotIDs); received.insert(package.packageid)
                    packageApps[package.packageid, default: []].formUnion(content.appIDs)
                }
            }
            guard received == Set(batch) else { throw SteamError.protocolError("PICS returned incomplete package ownership") }
        }
        return SteamEntitlements(appIDs: apps, depotIDs: depots,
            appAcquiredAt: Self.appAcquisitionDates(licenses: active, packages: packageApps, accountID: accountID))
    }
    internal static func appAcquisitionDates(licenses: [CMsgClientLicenseList.License], packages: [UInt32: Set<UInt32>],
                                             accountID: UInt32, now: Date = .now) -> [UInt32: Date] {
        var result: [UInt32: Date] = [:]
        for license in licenses where isOwnedActiveLicense(license, accountID: accountID) {
            guard license.timeCreated > 0 else { continue }
            let date = Date(timeIntervalSince1970: Double(license.timeCreated))
            guard date <= now else { continue }
            for app in packages[license.packageID] ?? [] {
                result[app] = min(result[app] ?? date, date)
            }
        }
        return result
    }
    internal static func isOwnedActiveLicense(_ license: CMsgClientLicenseList.License, accountID: UInt32) -> Bool {
        // ELicenseFlags: renewal failed, pending, expired, cancelled, fraud, not activated,
        // pending refund, borrowed, cancelled by partner. Region/content flags alone do not revoke it.
        let unavailable: UInt32 = 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x400 | 0x800 | 0x2000 | 0x4000 | 0x40000
        return license.packageID != 0 && license.flags & unavailable == 0
            && (license.ownerID == 0 || license.ownerID == accountID)
            && (license.minuteLimit <= 0 || license.minutesUsed < license.minuteLimit)
    }
    internal static func packageEntitlements(_ data: Data, packageID: UInt32) throws -> SteamEntitlements {
        guard data.count >= 5, data.count <= 8 * 1024 * 1024, data.readLE(UInt32.self, at: 0) == 1 else {
            throw SteamError.protocolError("unsupported PICS package buffer")
        }
        var reader = PackageKVReader(data: Data(data.dropFirst(4)))
        let value = try reader.section(depth: 0)
        guard reader.offset == reader.data.count, value.entries.count == 1,
              let root = value[String(packageID)] else { throw SteamError.protocolError("PICS package identity mismatch") }
        func ids(_ key: String) throws -> Set<UInt32> {
            var result = Set<UInt32>()
            for (_, value) in root[key]?.entries ?? [] {
                guard let raw = value.stringValue, let id = UInt32(raw) else { throw SteamError.protocolError("invalid package content ID") }
                result.insert(id)
            }
            return result
        }
        return try SteamEntitlements(appIDs: ids("appids"), depotIDs: ids("depotids"))
    }
}

private struct PackageKVReader {
    let data: Data
    var offset = 0
    var nodes = 0
    mutating func section(depth: Int) throws -> VDF {
        guard depth < 32 else { throw SteamError.protocolError("package nesting limit exceeded") }
        var pairs: [(String, VDF)] = [], keys = Set<String>()
        while offset < data.count {
            try Task.checkCancellation()
            let type = try integer(bytes: 1)
            if type == 8 { return .dict(pairs) }
            nodes += 1
            guard nodes <= 100_000 else { throw SteamError.protocolError("package entry limit exceeded") }
            let key = try string()
            let value: VDF
            switch type {
            case 0: value = try section(depth: depth + 1)
            case 1: value = .string(try string())
            case 2, 4, 6: value = .string(String(try integer(bytes: 4)))
            case 3: value = .string(String(Float(bitPattern: UInt32(try integer(bytes: 4)))))
            case 7, 10: value = .string(String(try integer(bytes: 8)))
            default: throw SteamError.protocolError("unsupported package value type")
            }
            guard keys.insert(key.lowercased()).inserted else {
                throw SteamError.protocolError("duplicate package key")
            }
            pairs.append((key, value))
        }
        throw SteamError.protocolError("truncated package section")
    }
    mutating func integer(bytes: Int) throws -> UInt64 {
        guard offset + bytes <= data.count else { throw SteamError.protocolError("truncated package value") }
        var result: UInt64 = 0
        for i in 0..<bytes { result |= UInt64(data[offset + i]) << (i * 8) }
        offset += bytes; return result
    }
    mutating func string() throws -> String {
        let start = offset
        while offset < data.count && data[offset] != 0 && offset - start <= 1024 * 1024 { offset += 1 }
        guard offset < data.count, data[offset] == 0, let value = String(data: data[start..<offset], encoding: .utf8) else {
            throw SteamError.protocolError("invalid package string")
        }
        offset += 1; return value
    }
}
