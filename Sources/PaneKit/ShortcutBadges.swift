import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// When each shortcut badge shows and how strongly. A badge fades in quickly, stays up,
/// and fades out about 1.5 seconds after its last press. A different shortcut replaces
/// it at once; pressing the same one again keeps it up and counts the presses ("×3").
public struct ShortcutBadgeTimeline: Sendable {
    public struct Badge: Sendable, Equatable {
        public struct Step: Sendable, Equatable {
            public var time: Double
            public var count: Int
        }

        public var label: String
        public var start: Double
        /// When it's gone: faded out, or replaced by the next badge.
        public var end: Double
        /// How visible it starts. A badge that replaces one still on screen starts as
        /// strong as that one was, so the swap doesn't flicker.
        public var startOpacity: Double
        /// Each press, with how many presses in a row it makes.
        public var steps: [Step]

        var lastPress: Double { steps.last?.time ?? start }
    }

    public struct State: Equatable, Sendable {
        public var label: String
        public var count: Int
        public var opacity: Double

        /// What the badge reads, with the count once a shortcut is repeated.
        public var text: String { count > 1 ? "\(label)  ×\(count)" : label }
    }

    /// Seconds a badge stays after its last press, including the fade out.
    public static let life = 1.5
    static let fadeIn = 0.12
    static let fadeOut = 0.4

    public let badges: [Badge]

    public init(presses: [ShortcutTrack.Press]) {
        var badges: [Badge] = []
        for press in presses.sorted(by: { $0.time < $1.time }) {
            let label = press.shortcut.label
            if var last = badges.last, press.time < last.lastPress + Self.life {
                if last.label == label {
                    last.steps.append(.init(time: press.time, count: (last.steps.last?.count ?? 1) + 1))
                    last.end = press.time + Self.life
                    badges[badges.count - 1] = last
                    continue
                }
                // A different shortcut replaces the badge on screen immediately.
                let showing = Self.opacity(of: last, at: press.time)
                badges[badges.count - 1].end = press.time
                badges.append(Badge(label: label, start: press.time, end: press.time + Self.life,
                                    startOpacity: showing, steps: [.init(time: press.time, count: 1)]))
            } else {
                badges.append(Badge(label: label, start: press.time, end: press.time + Self.life,
                                    startOpacity: 0, steps: [.init(time: press.time, count: 1)]))
            }
        }
        self.badges = badges
    }

    /// The badge showing at `time`, or nil when none is.
    public func state(at time: Double) -> State? {
        // The last badge starting at or before `time`.
        var low = 0, high = badges.count
        while low < high {
            let mid = (low + high) / 2
            if badges[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let badge = badges[low - 1]
        guard time < badge.end else { return nil }
        let opacity = Self.opacity(of: badge, at: time)
        guard opacity > 0 else { return nil }
        let count = badge.steps.last { $0.time <= time }?.count ?? 1
        return State(label: badge.label, count: count, opacity: opacity)
    }

    /// Fades in from `startOpacity`, then out over the end of its life (ignoring being
    /// replaced, which cuts it off).
    static func opacity(of badge: Badge, at time: Double) -> Double {
        guard time >= badge.start else { return 0 }
        let rise = badge.startOpacity + (1 - badge.startOpacity) * min(1, (time - badge.start) / fadeIn)
        let left = badge.lastPress + life - time
        let fall = max(0, min(1, left / fadeOut))
        let eased = fall * fall * (3 - 2 * fall)
        return min(rise, eased)
    }
}

/// Draws keyboard shortcut badges onto video frames: a dark see-through pill with white
/// text near the bottom center, sized to the video, kept clear of the camera circle.
/// Shared by export and the review window's preview.
public final class ShortcutBadgeRenderer: FrameEffect, @unchecked Sendable {
    private let timeline: ShortcutBadgeTimeline
    private let videoSize: CGSize
    private let cameraCircle: CGRect?
    /// Pixels at the bottom kept free for something else, such as burned-in captions; the
    /// pill sits above them.
    private let reservedBottom: CGFloat
    /// Each badge's picture, drawn once and reused on every frame it shows.
    private var cache: [String: CIImage] = [:]
    private let lock = NSLock()

    /// Pill height as a fraction of the video's height: about 65 px in a 1080p video.
    static let heightFraction = 0.06
    /// Gap between the pill and the bottom edge, as a fraction of the height.
    static let marginFraction = 0.06

    /// - Parameters:
    ///   - videoSize: The video's size in pixels.
    ///   - reservedBottom: Pixels at the bottom to stay above, such as
    ///     `CaptionRenderer.reservedHeight` when captions are burned in.
    public init?(track: ShortcutTrack, videoSize: CGSize, reservedBottom: CGFloat = 0) {
        guard !track.presses.isEmpty, videoSize.width > 0, videoSize.height > 0 else { return nil }
        timeline = ShortcutBadgeTimeline(presses: track.presses)
        self.videoSize = videoSize
        cameraCircle = track.cameraCircle
        self.reservedBottom = reservedBottom
    }

    public func isActive(at time: Double) -> Bool {
        (timeline.state(at: time)?.opacity ?? 0) > 0.002
    }

    public func apply(to frame: CIImage, at time: Double) -> CIImage {
        guard let state = timeline.state(at: time), state.opacity > 0.002 else { return frame }
        let extent = frame.extent
        let pill = image(for: state)
        let rect = placement(size: pill.extent.size, in: extent.size)
        let placed = pill
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: state.opacity)])
            .transformed(by: CGAffineTransform(translationX: extent.minX + rect.minX, y: extent.minY + rect.minY))
        // Blend in ordinary screen colors, like the pointer effects, so the gray of the
        // pill looks the same over light and dark screens as it would in a design tool.
        let screen = frame.matchedFromWorkingSpace(to: Self.screenColors) ?? frame
        let output = placed.composited(over: screen)
        return (output.matchedToWorkingSpace(from: Self.screenColors) ?? output).cropped(to: extent)
    }

    private static let screenColors = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Where the pill goes (pixels, bottom-left origin): bottom center, or beside the
    /// camera circle if they'd overlap, or above it if there's no room beside it.
    func placement(size: CGSize, in canvas: CGSize) -> CGRect {
        let gap = (canvas.height * 0.02).rounded()
        // Above the reserved part, scaled with the canvas (the preview can be smaller).
        let reserved = videoSize.height > 0 ? (reservedBottom * canvas.height / videoSize.height).rounded() : 0
        let margin = reserved > 0 ? reserved + gap : (canvas.height * Self.marginFraction).rounded()
        var rect = CGRect(x: ((canvas.width - size.width) / 2).rounded(), y: margin,
                          width: size.width, height: size.height)
        guard let circle = cameraCircle, circle.width > 0, circle.height > 0 else { return rect }
        let camera = CGRect(x: circle.minX * canvas.width, y: circle.minY * canvas.height,
                            width: circle.width * canvas.width, height: circle.height * canvas.height)
        guard rect.intersects(camera.insetBy(dx: -gap, dy: -gap)) else { return rect }

        // Slide sideways, away from the camera, just far enough.
        var beside = rect
        beside.origin.x = camera.midX > canvas.width / 2 ? camera.minX - gap - size.width : camera.maxX + gap
        if beside.minX >= gap, beside.maxX <= canvas.width - gap { return beside }
        // No room: sit above the camera instead.
        rect.origin.y = camera.maxY + gap
        return rect
    }

    private func image(for state: ShortcutBadgeTimeline.State) -> CIImage {
        let text = state.text
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[text] { return cached }
        let image = Self.draw(label: state.label, count: state.count, height: videoSize.height * Self.heightFraction)
        cache[text] = image
        return image
    }

    /// The pill, drawn at the video's own pixel size so the text stays sharp.
    static func draw(label: String, count: Int, height rawHeight: Double) -> CIImage {
        let height = max(18, rawHeight.rounded())
        let font = badgeFont(size: height * 0.5)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let text = NSMutableAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ])
        if count > 1 {
            text.append(NSAttributedString(string: "  ×\(count)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.65),
            ]))
        }
        let line = CTLineCreateWithAttributedString(text)
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let padding = height * 0.5
        let width = max(height * 1.6, (textWidth + padding * 2).rounded(.up))

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CIImage.empty() }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let pill = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: height / 2 - 0.5,
                          cornerHeight: height / 2 - 0.5, transform: nil)
        context.addPath(pill)
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 0.82))
        context.fillPath()
        // A faint light edge keeps the pill distinct on dark screens.
        context.addPath(pill)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
        context.setLineWidth(1)
        context.strokePath()

        // Center on the capital letters' height, so letters and symbols sit in the middle.
        let capHeight = CTFontGetCapHeight(font)
        context.textPosition = CGPoint(x: (width - textWidth) / 2, y: (height - capHeight) / 2)
        CTLineDraw(line, context)

        guard let cgImage = context.makeImage() else { return CIImage.empty() }
        // No color matching: the pixels are already screen colors, and they're blended
        // over the frame in screen colors.
        return CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
    }

    /// The system font, semibold.
    private static func badgeFont(size: Double) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let traits = [kCTFontWeightTrait: 0.3] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}
