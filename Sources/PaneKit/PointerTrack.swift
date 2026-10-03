import CoreGraphics
import Foundation

/// Where the pointer was during a recording, what shape it had, and every click, on the
/// video's own timeline. Pane saves it with the recording so pointer effects can be
/// added, changed or removed when exporting.
public struct PointerTrack: Codable, Sendable, Equatable {
    public struct Sample: Codable, Sendable, Equatable {
        /// Seconds into the video.
        public var time: Double
        /// Normalized (0–1), bottom-left origin, like the rest of PaneKit.
        public var x: Double
        public var y: Double
        /// The pointer was the pointing hand, which apps show over links and buttons.
        public var isHand: Bool

        public init(time: Double, x: Double, y: Double, isHand: Bool) {
            self.time = time
            self.x = x
            self.y = y
            self.isHand = isHand
        }

        enum CodingKeys: String, CodingKey {
            case time = "t", x, y, isHand = "h"
        }
    }

    public enum Button: String, Codable, Sendable {
        case left, right, other
    }

    public struct Click: Codable, Sendable, Equatable, Identifiable {
        public var id = UUID()
        public var time: Double
        public var x: Double
        public var y: Double
        public var button: Button
        /// Clicked with the pointing hand: almost always a link or button.
        public var isHand: Bool
        /// How long the button was held down.
        public var duration: Double
        public var isEnabled = true

        public init(time: Double, x: Double, y: Double, button: Button, isHand: Bool, duration: Double) {
            self.time = time
            self.x = x
            self.y = y
            self.button = button
            self.isHand = isHand
            self.duration = duration
        }
    }

    /// Sorted by time. Only changes are kept, plus the end of each still stretch.
    public var samples: [Sample]
    public var clicks: [Click]
    /// One screen point as a fraction of the video's height, so effects can be sized
    /// to match the real pointer at any resolution.
    public var pointSize: Double
    /// The camera circle (normalized, bottom-left origin), where the real pointer is
    /// hidden and effects shouldn't be drawn.
    public var cameraCircle: CGRect?

    public init(samples: [Sample], clicks: [Click], pointSize: Double, cameraCircle: CGRect?) {
        self.samples = samples
        self.clicks = clicks
        self.pointSize = pointSize
        self.cameraCircle = cameraCircle
    }

    /// Where the pointer was at `time`, normalized, or nil before the first sample.
    public func position(at time: Double) -> (point: CGPoint, isHand: Bool)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.time { return (CGPoint(x: first.x, y: first.y), first.isHand) }
        if time >= last.time { return (CGPoint(x: last.x, y: last.y), last.isHand) }
        var low = 0
        var high = samples.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if samples[mid].time <= time { low = mid } else { high = mid }
        }
        let a = samples[low], b = samples[high]
        let t = (time - a.time) / max(b.time - a.time, 0.0001)
        return (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), a.isHand)
    }
}

// MARK: - Saving with the video

extension PointerTrack {
    /// Stored in the video file's extended attributes, so it travels with the file when
    /// it's moved or renamed, without an extra file next to it.
    static let attributeName = "com.jacobhokanson.pane.pointer"

    public func save(to url: URL) throws {
        let json = try JSONEncoder().encode(self)
        let data = try (json as NSData).compressed(using: .lzfse) as Data
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, Self.attributeName, bytes.baseAddress, bytes.count, 0, 0)
        }
        if result != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    /// The pointer recorded with `url`, or nil for videos Pane didn't record.
    public static func load(from url: URL) -> PointerTrack? {
        let size = getxattr(url.path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, attributeName, bytes.baseAddress, size, 0, 0)
        }
        guard read == size,
              let json = try? (data as NSData).decompressed(using: .lzfse) as Data
        else { return nil }
        return try? JSONDecoder().decode(PointerTrack.self, from: json)
    }
}
