import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads the executable's first RT_GROUP_ICON and its RT_ICON images without starting Wine.
/// Layout: https://learn.microsoft.com/windows/win32/debug/pe-format#the-rsrc-section
/// https://devblogs.microsoft.com/oldnewthing/20120720-00/?p=7083
/// A missing or malformed icon is optional metadata, never a failed installation.
enum WindowsExecutableIcon {
    static func png(at executable: URL) -> Data? {
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
              let ico = try? icon(in: data), let source = CGImageSourceCreateWithData(ico as CFData, nil) else { return nil }
        let indices = (0..<CGImageSourceGetCount(source)).sorted { a, b in
            func size(_ index: Int) -> Int {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            }
            return size(a) > size(b)
        }
        guard let index = indices.first,
              let image = CGImageSourceCreateImageAtIndex(source, index, nil), image.width <= 1024, image.height <= 1024 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func icon(in data: Data) throws -> Data {
        func bytes(_ offset: Int, _ count: Int) throws -> Data {
            guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else { throw Invalid.icon }
            return data.subdata(in: offset..<(offset + count))
        }
        func number(_ offset: Int, _ count: Int = 4) throws -> Int {
            try bytes(offset, count).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        }
        guard try bytes(0, 2) == Data([0x4d, 0x5a]) else { throw Invalid.icon }
        let pe = try number(0x3c)
        guard try bytes(pe, 4) == Data([0x50, 0x45, 0, 0]) else { throw Invalid.icon }
        let optional = pe + 24, optionalSize = try number(pe + 20, 2), magic = try number(optional, 2)
        guard magic == 0x10b || magic == 0x20b else { throw Invalid.icon }
        let directories = magic == 0x20b ? 112 : 96
        guard optionalSize >= directories + 24, try number(optional + directories - 4) >= 3 else { throw Invalid.icon }
        let resourceRVA = try number(optional + directories + 16), resourceSize = try number(optional + directories + 20)
        let sectionCount = try number(pe + 6, 2), sectionStart = optional + optionalSize
        guard sectionCount > 0, sectionCount <= 96, resourceRVA > 0, resourceSize >= 16 else { throw Invalid.icon }
        func fileOffset(_ rva: Int, count: Int) throws -> Int {
            for index in 0..<sectionCount {
                let section = sectionStart + index * 40
                let address = try number(section + 12), size = try number(section + 16), raw = try number(section + 20)
                let delta = rva - address
                if delta >= 0, delta <= size, count <= size - delta {
                    let offset = raw + delta
                    guard offset <= data.count, count <= data.count - offset else { throw Invalid.icon }
                    return offset
                }
            }
            throw Invalid.icon
        }
        let root = try fileOffset(resourceRVA, count: resourceSize)
        func entries(_ relative: Int) throws -> [(id: Int, target: Int)] {
            guard relative >= 0, relative <= resourceSize - 16 else { throw Invalid.icon }
            let offset = root + relative
            let named = try number(offset + 12, 2), count = try number(offset + 14, 2)
            guard named + count <= 4096, 16 + (named + count) * 8 <= resourceSize - relative else { throw Invalid.icon }
            return try (0..<(named + count)).map { index in
                let entry = offset + 16 + index * 8
                return (try number(entry), try number(entry + 4))
            }
        }
        func child(_ target: Int) throws -> Int {
            guard target & 0x80000000 != 0 else { throw Invalid.icon }
            return target & 0x7fffffff
        }
        func resource(_ type: Int, id: Int? = nil) throws -> Data {
            guard let category = try entries(0).first(where: { $0.id == type }),
                  let name = try entries(child(category.target)).first(where: { id == nil || $0.id == id }),
                  let language = try entries(child(name.target)).first,
                  language.target & 0x80000000 == 0, language.target <= resourceSize - 16 else { throw Invalid.icon }
            let entry = root + language.target
            let rva = try number(entry), size = try number(entry + 4)
            guard size > 0, size <= 4 * 1024 * 1024 else { throw Invalid.icon }
            return try bytes(fileOffset(rva, count: size), size)
        }
        let group = try resource(14)
        guard group.count >= 6, group[0] == 0, group[1] == 0, group[2] == 1, group[3] == 0 else { throw Invalid.icon }
        let count = Int(group[4]) | Int(group[5]) << 8
        guard count > 0, count <= 256, group.count >= 6 + count * 14 else { throw Invalid.icon }
        var result = Data(group.prefix(6)), images = Data(), offset = 6 + count * 16
        func little(_ value: Int) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) }) }
        for index in 0..<count {
            let start = 6 + index * 14
            let id = Int(group[start + 12]) | Int(group[start + 13]) << 8
            let image = try resource(3, id: id)
            guard offset + image.count <= 16 * 1024 * 1024 else { throw Invalid.icon }
            result.append(group[start..<(start + 8)])
            result.append(little(image.count)); result.append(little(offset))
            images.append(image); offset += image.count
        }
        result.append(images)
        return result
    }
    private enum Invalid: Error { case icon }
}
