import Foundation
import CryptoKit

/// The stable device fields the real Steam client sends on every CM logon. Steam uses them to tell
/// sessions from the same sign-in apart; a logon without them looks like a new, anonymous client each time.
public struct CMDeviceIdentity: Equatable, Sendable {
    /// Sent as `obfuscated_private_ip`. Logons that share it replace each other's session.
    public let loginID: UInt32
    public let machineName: String
    /// SteamKit's `MessageObject` layout: binary KeyValues with the hashed BB3, FF2 and 3B3 hardware keys.
    public let machineID: Data

    /// Derives every field from `seed`, a random per-install value, so no real hardware identifier leaves the Mac.
    public init(seed: String, machineName: String) {
        let digest = Array(SHA256.hash(data: Data("login-id:\(seed)".utf8)))
        let loginID = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        self.loginID = loginID == 0 ? 1 : loginID
        self.machineName = machineName
        var object = Data([0x00]) + Data("MessageObject".utf8) + Data([0x00])
        for key in ["BB3", "FF2", "3B3"] {
            let hash = Insecure.SHA1.hash(data: Data("\(key):\(seed)".utf8)).map { String(format: "%02x", $0) }.joined()
            object += Data([0x01]) + Data(key.utf8) + Data([0x00]) + Data(hash.utf8) + Data([0x00])
        }
        self.machineID = object + Data([0x08, 0x08])
    }
}
