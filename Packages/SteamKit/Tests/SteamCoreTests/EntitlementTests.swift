import XCTest
import SteamProto
@testable import SteamCore

final class EntitlementTests: XCTestCase {
    func testAcquisitionDatesUseEarliestOwnedPackageAndIgnoreInvalidLicenses() {
        func license(_ package: UInt32, _ time: UInt32, owner: UInt32 = 123, flags: UInt32 = 0) -> CMsgClientLicenseList.License {
            var value = CMsgClientLicenseList.License()
            value.packageID = package; value.timeCreated = time; value.ownerID = owner; value.flags = flags
            return value
        }
        let licenses = [
            license(1, 100), license(2, 300), // App 100 was acquired before the later bundle.
            license(3, 50, owner: 456), license(4, 40, flags: 8), // Foreign and expired.
            license(5, 0), license(6, 2000), // Unknown/future dates are not acquisitions.
            license(7, 250, owner: 0), // Steam can omit the owner for this account's license.
            license(8, 200), license(8, 150), // Duplicate package licenses: earliest wins.
        ]
        let packages: [UInt32: Set<UInt32>] = [1: [100], 2: [100, 200], 3: [100, 300], 4: [100, 400],
                                               5: [500], 6: [600], 7: [700], 8: [800]]
        let result = CMClient.appAcquisitionDates(licenses: licenses, packages: packages, accountID: 123,
                                                 now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(result, [100: Date(timeIntervalSince1970: 100), 200: Date(timeIntervalSince1970: 300),
                                700: Date(timeIntervalSince1970: 250), 800: Date(timeIntervalSince1970: 150)])
        XCTAssertEqual(CMClient.appAcquisitionDates(licenses: licenses.reversed(), packages: packages,
            accountID: 123, now: Date(timeIntervalSince1970: 1000)), result)
    }

    func testPackageBinaryKVExtractsAppsAndDepotsWithoutGrantingAdvertisedDLC() throws {
        let data = package(section("appids", integer("0", 100) + integer("1", 200))
            + section("depotids", integer("0", 101)) + section("extended", string("listofdlc", "999")))
        let result = try CMClient.packageEntitlements(data, packageID: 42)
        XCTAssertEqual(result.appIDs, [100, 200]); XCTAssertEqual(result.depotIDs, [101])
        XCTAssertFalse(result.appIDs.contains(999))
    }
    func testPackageRejectsIdentityMismatchTruncationDuplicateKeysAndInvalidIDs() throws {
        let valid = package(section("appids", integer("0", 100)))
        XCTAssertThrowsError(try CMClient.packageEntitlements(valid, packageID: 43))
        for count in 0..<valid.count {
            XCTAssertThrowsError(try CMClient.packageEntitlements(Data(valid.prefix(count)), packageID: 42))
        }
        XCTAssertThrowsError(try CMClient.packageEntitlements(valid + Data([8]), packageID: 42))
        XCTAssertThrowsError(try CMClient.packageEntitlements(package(section("appids", integer("0", 1) + integer("0", 2))), packageID: 42))
        XCTAssertThrowsError(try CMClient.packageEntitlements(package(section("appids", string("0", "-1"))), packageID: 42))
    }
    func testOnlyActiveOwnedLicensesContributeEntitlements() {
        var license = CMsgClientLicenseList.License(); license.packageID = 42; license.ownerID = 123
        XCTAssertTrue(CMClient.isOwnedActiveLicense(license, accountID: 123))
        XCTAssertFalse(CMClient.isOwnedActiveLicense(license, accountID: 124))
        for denied: UInt32 in [2, 4, 8, 0x10, 0x20, 0x400, 0x800, 0x2000, 0x4000, 0x40000] {
            license.flags = denied
            XCTAssertFalse(CMClient.isOwnedActiveLicense(license, accountID: 123), "flag \(denied)")
        }
        license.flags = 0x40 | 0x100
        XCTAssertTrue(CMClient.isOwnedActiveLicense(license, accountID: 123))
        license.minuteLimit = 60; license.minutesUsed = 59
        XCTAssertTrue(CMClient.isOwnedActiveLicense(license, accountID: 123))
        license.minutesUsed = 60
        XCTAssertFalse(CMClient.isOwnedActiveLicense(license, accountID: 123))
    }
    private func package(_ body: Data) -> Data { Data([1, 0, 0, 0]) + section("42", body) + Data([8]) }
    private func section(_ key: String, _ body: Data) -> Data { Data([0]) + cString(key) + body + Data([8]) }
    private func string(_ key: String, _ value: String) -> Data { Data([1]) + cString(key) + cString(value) }
    private func integer(_ key: String, _ value: UInt32) -> Data {
        Data([2]) + cString(key) + Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func cString(_ value: String) -> Data { Data(value.utf8) + Data([0]) }
}
