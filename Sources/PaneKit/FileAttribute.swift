import Compression
import CoreGraphics
import Foundation

/// What Pane keeps with a recording (pointer, shortcuts, script) lives in the video
/// file's extended attributes, so it travels with the file. A video can come from
/// anywhere, attributes and all, so reading them is bounded.
enum FileAttribute {
    /// Far above anything Pane writes: a two-hour pointer track is a few MB packed.
    static let packedLimit = 16 << 20
    static let unpackedLimit = 128 << 20

    static func write(_ data: Data, name: String, to url: URL) throws {
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        if result != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    /// The attribute's bytes, or nil if it's missing or over `limit`.
    static func read(_ name: String, from url: URL, limit: Int) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0, size <= limit else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, name, bytes.baseAddress, size, 0, 0)
        }
        return read == size ? data : nil
    }

    /// Stores `value` as LZFSE-packed JSON.
    static func writePacked<T: Encodable>(_ value: T, name: String, to url: URL) throws {
        let json = try JSONEncoder().encode(value)
        try write(try (json as NSData).compressed(using: .lzfse) as Data, name: name, to: url)
    }

    /// What `writePacked` stored, or nil if it's missing, unreadable or too large.
    static func readPacked<T: Decodable>(_ type: T.Type, name: String, from url: URL) -> T? {
        guard let data = read(name, from: url, limit: packedLimit),
              let json = unpacked(data, limit: unpackedLimit)
        else { return nil }
        return try? JSONDecoder().decode(type, from: json)
    }

    /// LZFSE-unpacked, giving up past `limit` bytes: a small attribute can unpack to
    /// gigabytes.
    static func unpacked(_ data: Data, limit: Int) -> Data? {
        var output = Data()
        do {
            let filter = try OutputFilter(.decompress, using: .lzfse) { chunk in
                guard let chunk else { return }
                guard output.count + chunk.count <= limit else { throw CocoaError(.fileReadTooLarge) }
                output.append(chunk)
            }
            try filter.write(data)
            try filter.finalize()
        } catch {
            return nil
        }
        return output
    }

    /// Seconds into a recording that could be real: finite, and within a day.
    static func isPlausibleTime(_ time: Double) -> Bool {
        time.isFinite && time >= 0 && time <= 86_400
    }

    /// Normalized coordinates that could be real (a pointer can be a little off-screen).
    static func isPlausible(_ values: Double...) -> Bool {
        values.allSatisfy { $0.isFinite && abs($0) <= 100 }
    }

    static func isPlausible(_ rect: CGRect?) -> Bool {
        guard let rect else { return true }
        return isPlausible(rect.minX, rect.minY, rect.width, rect.height)
    }
}
