import Foundation

public enum PEArchitecture: String, Sendable {
    case x86
    case x86_64
}

public struct PEInspection: Sendable {
    public let architecture: PEArchitecture
    public let entryPointRVA: UInt32
    public let entryPointSection: String?

    public var requiresSteamStubRuntime: Bool {
        entryPointSection?.caseInsensitiveCompare(".bind") == .orderedSame
    }
}

/// The M4 contract needs the DLL architecture and the executable entry-point
/// section. This intentionally parses only the PE/COFF fields needed for those
/// two decisions.
public enum PEInspector {
    public static func inspect(_ url: URL) throws -> PEInspection {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 0x40, data[0] == 0x4d, data[1] == 0x5a else {
            throw SteamError.prepare("\(url.lastPathComponent) is not a PE file (missing MZ)")
        }
        let peOffset = Int(try uint32(data, at: 0x3c))
        guard peOffset >= 0, peOffset + 24 <= data.count,
              data[peOffset] == 0x50, data[peOffset + 1] == 0x45,
              data[peOffset + 2] == 0, data[peOffset + 3] == 0 else {
            throw SteamError.prepare("\(url.lastPathComponent) has an invalid PE header")
        }

        let machine = try uint16(data, at: peOffset + 4)
        let architecture: PEArchitecture
        switch machine {
        case 0x014c: architecture = .x86
        case 0x8664: architecture = .x86_64
        default:
            throw SteamError.prepare(String(format: "%@ has unsupported PE machine 0x%04x",
                                            url.lastPathComponent, machine))
        }

        let sectionCount = Int(try uint16(data, at: peOffset + 6))
        let optionalHeaderSize = Int(try uint16(data, at: peOffset + 20))
        let optionalHeader = peOffset + 24
        guard optionalHeaderSize >= 20, optionalHeader + optionalHeaderSize <= data.count else {
            throw SteamError.prepare("\(url.lastPathComponent) has a truncated optional header")
        }
        let magic = try uint16(data, at: optionalHeader)
        guard magic == 0x10b || magic == 0x20b else {
            throw SteamError.prepare(String(format: "%@ has unsupported optional-header magic 0x%04x",
                                            url.lastPathComponent, magic))
        }
        let entryPoint = try uint32(data, at: optionalHeader + 16)

        let sectionTable = optionalHeader + optionalHeaderSize
        guard sectionCount <= 96, sectionTable + sectionCount * 40 <= data.count else {
            throw SteamError.prepare("\(url.lastPathComponent) has a truncated section table")
        }
        var entrySection: String?
        for index in 0..<sectionCount {
            let offset = sectionTable + index * 40
            let nameBytes = data[offset..<offset + 8].prefix { $0 != 0 }
            let name = String(bytes: nameBytes, encoding: .ascii) ?? ""
            let virtualSize = try uint32(data, at: offset + 8)
            let virtualAddress = try uint32(data, at: offset + 12)
            let rawSize = try uint32(data, at: offset + 16)
            let span = max(virtualSize, rawSize)
            if entryPoint >= virtualAddress && UInt64(entryPoint) < UInt64(virtualAddress) + UInt64(span) {
                entrySection = name
                break
            }
        }

        return PEInspection(architecture: architecture, entryPointRVA: entryPoint,
                            entryPointSection: entrySection)
    }

    private static func uint16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw SteamError.prepare("truncated PE field")
        }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw SteamError.prepare("truncated PE field")
        }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
