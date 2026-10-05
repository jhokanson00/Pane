import CoreGraphics
import Foundation

/// Where a finding was on screen at one moment. `rect` is normalized (0–1) with a
/// bottom-left origin, matching Vision and Core Image.
public struct BoxSample: Codable, Sendable, Equatable {
    public var time: Double
    public var rect: CGRect

    public init(time: Double, rect: CGRect) {
        self.time = time
        self.rect = rect
    }
}

/// The outline of a blur.
public enum BlurShape: String, Codable, Sendable {
    case rectangle
    /// Fills the box as an oval (a circle when the box is square).
    case ellipse
}

/// One thing to blur: a piece of sensitive text tracked over time, or a shape you drew.
public struct Finding: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var kind: SensitiveKind
    public var text: String
    /// Sorted by time.
    public var samples: [BoxSample]
    /// Seconds into the video when the blur starts and stops.
    public var start: Double
    public var end: Double
    public var isEnabled = true
    public var shape: BlurShape

    public init(kind: SensitiveKind, text: String, samples: [BoxSample], start: Double, end: Double,
                shape: BlurShape = .rectangle) {
        self.kind = kind
        self.text = text
        self.samples = samples
        self.start = start
        self.end = end
        self.shape = shape
    }

    /// The area to blur at `time` (normalized, bottom-left origin), or nil if this
    /// finding isn't active then. Detected text gets a thin margin so letter edges
    /// don't peek out.
    /// - Parameter aspect: The video's width / height, so the margin is even on all sides.
    public func coverRect(at time: Double, aspect: CGFloat) -> CGRect? {
        guard isEnabled, time >= start, time <= end, let rect = interpolatedRect(at: time) else { return nil }
        guard kind != .manual else { return rect }
        // At least a couple of pixels, so tiny text's margin isn't under one.
        let padY = max(rect.height * 0.18, 0.0025)
        let padX = padY / max(aspect, 0.1)
        // Not cut to the screen: the blur's look depends on its size, so a box sliding
        // off the edge must keep its size to avoid flickering.
        return rect.insetBy(dx: -padX, dy: -padY)
    }

    /// Longer than two frames at 60 fps, shorter than two at 30.
    static let untrackedGap = 0.05

    func interpolatedRect(at time: Double) -> CGRect? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.time { return first.rect }
        if time >= last.time { return last.rect }

        // Binary search for the samples on either side of `time`.
        var low = 0
        var high = samples.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if samples[mid].time <= time { low = mid } else { high = mid }
        }
        let a = samples[low]
        let b = samples[high]
        // A gap of more than a frame or so means the text couldn't be followed there,
        // usually in a fast flick. Its path between the two known spots isn't a straight
        // line in time (scrolls speed up and slow down), so cover all of it.
        let moved = max(abs(b.rect.midX - a.rect.midX), abs(b.rect.midY - a.rect.midY))
        if b.time - a.time > Self.untrackedGap, moved > min(a.rect.height, b.rect.height) / 2 {
            return a.rect.union(b.rect)
        }
        let t = (time - a.time) / max(b.time - a.time, 0.0001)
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return CGRect(
            x: lerp(a.rect.minX, b.rect.minX),
            y: lerp(a.rect.minY, b.rect.minY),
            width: lerp(a.rect.width, b.rect.width),
            height: lerp(a.rect.height, b.rect.height)
        )
    }

    /// The text with its middle hidden, for showing in lists.
    public var maskedText: String {
        guard kind != .customWord, kind != .manual else { return text }
        let chars = Array(text)
        guard chars.count > 6 else { return String(chars.prefix(1)) + String(repeating: "•", count: max(chars.count - 1, 3)) }
        let keep = min(4, chars.count / 4)
        return String(chars.prefix(keep)) + String(repeating: "•", count: 6) + String(chars.suffix(keep))
    }
}

// MARK: - Saving with the video

extension Finding {
    /// A video's blur layers, kept in its extended attributes like the pointer track, so
    /// reviewing it again starts from what was blurred before. Without them, exporting
    /// again would replace the blurred copy with an unblurred one.
    static let attributeName = "com.jacobhokanson.pane.blurs"

    public static func save(_ findings: [Finding], to url: URL) throws {
        try FileAttribute.writePacked(findings, name: attributeName, to: url)
    }

    /// The layers saved with `url`, or nil if none were (or they make no sense).
    public static func load(from url: URL) -> [Finding]? {
        FileAttribute.readPacked([Finding].self, name: attributeName, from: url).flatMap { findings in
            findings.allSatisfy(\.isPlausible) ? findings : nil
        }
    }

    var isPlausible: Bool {
        FileAttribute.isPlausibleTime(start) && FileAttribute.isPlausibleTime(end) && text.count <= 1000
            && samples.allSatisfy { FileAttribute.isPlausibleTime($0.time) && FileAttribute.isPlausible($0.rect) }
    }

    /// The layers after a new scan: what it found replaces what an earlier scan found,
    /// and blurs you drew or picked with Blur Text stay. (A picked word the new scan
    /// also found, from the word list, isn't kept twice.)
    public static func merging(_ earlier: [Finding], scanned: [Finding]) -> [Finding] {
        let kept = earlier.filter { old in
            switch old.kind {
            case .manual:
                true
            case .customWord:
                !scanned.contains {
                    $0.kind == .customWord && $0.text.lowercased() == old.text.lowercased()
                        && $0.start <= old.end && old.start <= $0.end
                }
            default:
                false
            }
        }
        return kept + scanned
    }
}
