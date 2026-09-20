import Foundation
import Domain

extension SaveStore {
    /// The offline runtime keeps its generated identity in the portable settings folder.
    /// Read it beneath the ownership-checked bottle without following links. On first launch,
    /// initialize that same file once so Cloud downloads land where the game will look.
    public func steamLocalAccountID(roots: [SaveRoot: URL], createIfMissing: Bool = true) throws -> UInt64 {
        guard let root = roots[.bottle] else { throw saveFailure("The game's save account folder is unavailable.") }
        let directory = try SaveDirectory(url: root)
        let path = "drive_c/Program Files (x86)/Steam/userdata/0/settings/configs.user.ini"
        if let file = try directory.file(path) {
            return try Self.steamLocalAccountID(in: file.contents(maximum: 64 * 1024))
        }
        guard createIfMissing else { throw saveFailure("The game has not initialized its local save account yet.") }
        let id = UInt64(0x0110000100000000) | UInt64(UInt32.random(in: 1...UInt32.max))
        let data = Data("[user::general]\naccount_steamid=\(id)\n".utf8)
        try directory.write(data, to: path) // Atomic, exclusive publication; never replaces an identity.
        return id
    }

    static func steamLocalAccountID(in data: Data) throws -> UInt64 {
        guard let text = String(data: data, encoding: .utf8) else { throw saveFailure("The game's local save account cannot be read.") }
        var section = "", identities: [UInt64] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()).lowercased(); continue }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if section == "user::general", pair.count == 2, pair[0].lowercased() == "account_steamid" {
                guard pair[1].allSatisfy({ $0.isASCII && $0.isNumber }), let id = UInt64(pair[1]),
                      id >> 32 == 0x01100001, UInt32(truncatingIfNeeded: id) != 0 else {
                    throw saveFailure("The game's local save account is invalid. Its settings and saves have been kept.")
                }
                identities.append(id)
            }
        }
        guard identities.count == 1 else { throw saveFailure("The game's local save account is missing or ambiguous. Its settings and saves have been kept.") }
        return identities[0]
    }
}
