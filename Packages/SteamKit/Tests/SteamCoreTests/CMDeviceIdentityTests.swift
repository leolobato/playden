import Foundation
import XCTest
@testable import SteamCore

final class CMDeviceIdentityTests: XCTestCase {
    func testIdentityIsStablePerSeedAndDistinctAcrossSeeds() {
        let first = CMDeviceIdentity(seed: "install-a", machineName: "Playden")
        XCTAssertEqual(first, CMDeviceIdentity(seed: "install-a", machineName: "Playden"))
        let other = CMDeviceIdentity(seed: "install-b", machineName: "Playden")
        XCTAssertNotEqual(first.loginID, other.loginID)
        XCTAssertNotEqual(first.machineID, other.machineID)
        XCTAssertNotEqual(first.loginID, 0)
    }

    func testMachineIDUsesTheBinaryMessageObjectLayout() {
        let bytes = [UInt8](CMDeviceIdentity(seed: "install-a", machineName: "Playden").machineID)
        XCTAssertEqual(Array(bytes.prefix(15)), [0x00] + Array("MessageObject".utf8) + [0x00])
        XCTAssertEqual(Array(bytes.suffix(2)), [0x08, 0x08])
        let text = String(decoding: bytes, as: UTF8.self)
        for key in ["BB3", "FF2", "3B3"] { XCTAssertTrue(text.contains("\u{01}\(key)\u{00}"), key) }
        // Three string entries: type byte, key, NUL, 40 hex characters, NUL.
        XCTAssertEqual(bytes.count, 15 + 3 * (1 + 3 + 1 + 40 + 1) + 2)
    }

    func testLogonCarriesTheDeviceIdentity() {
        let device = CMDeviceIdentity(seed: "install-a", machineName: "Playden")
        let logon = CMClient.logonMessage(accountName: "fixture", refreshToken: "not-a-token", cellID: 7, device: device)
        XCTAssertEqual(logon.obfuscatedPrivateIp.v4, device.loginID)
        XCTAssertEqual(logon.machineName, "Playden")
        XCTAssertEqual(logon.machineID, device.machineID)
        let anonymous = CMClient.logonMessage(accountName: "fixture", refreshToken: "not-a-token", cellID: 7, device: nil)
        XCTAssertFalse(anonymous.hasObfuscatedPrivateIp)
        XCTAssertFalse(anonymous.hasMachineID)
    }
}
