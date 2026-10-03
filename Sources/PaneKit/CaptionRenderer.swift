import AppKit
import CoreImage

/// Draws captions into the video: white text on a dark rounded box near the bottom
/// center, sized to the video's height so they read the same at any resolution. A
/// caption that would cover the camera circle moves aside, or above it.
public final class CaptionRenderer: FrameEffect, @unchecked Sendable {
    private let captions: Captions
    private let videoSize: CGSize
    /// The camera circle in pixels, bottom-left origin.
    private let camera: CGRect?
    private let lock = NSLock()
    private var cache: [Int: (image: CIImage, origin: CGPoint)] = [:]

    /// - Parameters:
    ///   - videoSize: The video's size in pixels.
    ///   - cameraCircle: Where the camera circle is (normalized, bottom-left origin), if
    ///     it's drawn into the video.
    public init?(captions: Captions, videoSize: CGSize, cameraCircle: CGRect?) {
        guard !captions.cues.isEmpty, videoSize.width > 0, videoSize.height > 0 else { return nil }
        self.captions = captions
        self.videoSize = videoSize
        camera = cameraCircle.flatMap { circle in
            guard circle.width > 0, circle.height > 0 else { return nil }
            return CGRect(x: circle.minX * videoSize.width, y: circle.minY * videoSize.height,
                          width: circle.width * videoSize.width, height: circle.height * videoSize.height)
        }
    }

    public func isActive(at time: Double) -> Bool {
        captions.cue(at: time) != nil
    }

    public func apply(to frame: CIImage, at time: Double) -> CIImage {
        guard let index = index(at: time), let (image, origin) = rendered(index) else { return frame }
        // Laid on in ordinary screen colors, so the box's darkness matches what was drawn,
        // as the pointer effects do.
        let extent = frame.extent
        let screen = frame.matchedFromWorkingSpace(to: Self.screenColors) ?? frame
        let placed = image.transformed(by: CGAffineTransform(translationX: extent.minX + origin.x,
                                                             y: extent.minY + origin.y))
        let output = placed.composited(over: screen)
        return (output.matchedToWorkingSpace(from: Self.screenColors) ?? output).cropped(to: extent)
    }

    private static let screenColors = CGColorSpace(name: CGColorSpace.sRGB)!

    private func index(at time: Double) -> Int? {
        captions.cueIndex(at: time)
    }

    /// Each caption is drawn once and reused for every frame it's on.
    private func rendered(_ index: Int) -> (CIImage, CGPoint)? {
        if let hit = lock.withLock({ cache[index] }) { return hit }
        guard let image = Self.draw(captions.cues[index].lines, videoSize: videoSize) else { return nil }
        let origin = place(CGSize(width: image.width, height: image.height))
        // Pixel values as drawn, with no color matching: they're already screen colors.
        let result = (CIImage(cgImage: image, options: [.colorSpace: NSNull()]), origin)
        lock.withLock { cache[index] = result }
        return result
    }

    /// How much of the bottom a two-line caption takes, from the bottom edge to the top
    /// of its box, in pixels: room other things near the bottom (like the shortcut
    /// badges) keep clear of, so they don't move each time a caption comes or goes.
    public static func reservedHeight(videoSize: CGSize) -> CGFloat {
        let box = draw(["Ag", "Ag"], videoSize: videoSize).map { CGFloat($0.height) } ?? videoSize.height * 0.13
        return (videoSize.height * 0.06).rounded() + box
    }

    /// Bottom center, unless that covers the camera: then slid sideways away from it,
    /// or lifted above it if sliding isn't enough.
    func place(_ size: CGSize) -> CGPoint {
        let margin = (videoSize.height * 0.02).rounded()
        var box = CGRect(x: ((videoSize.width - size.width) / 2).rounded(), y: (videoSize.height * 0.06).rounded(),
                         width: size.width, height: size.height)
        guard let camera, box.intersects(camera.insetBy(dx: -margin, dy: -margin)) else { return box.origin }
        let slid = camera.midX > videoSize.width / 2
            ? box.offsetBy(dx: camera.minX - margin - box.maxX, dy: 0)
            : box.offsetBy(dx: camera.maxX + margin - box.minX, dy: 0)
        if slid.minX >= margin && slid.maxX <= videoSize.width - margin { return slid.origin }
        box.origin.y = min(camera.maxY + margin, videoSize.height - size.height - margin)
        return box.origin
    }

    /// The caption as an image: centered lines on a rounded dark box.
    static func draw(_ lines: [String], videoSize: CGSize) -> CGImage? {
        var fontSize = (videoSize.height * 0.042).rounded()
        func layout(_ size: CGFloat) -> (lines: [CTLine], widths: [CGFloat], font: NSFont) {
            let font = NSFont.systemFont(ofSize: size, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.white,
            ]
            let ctLines = lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
            return (ctLines, ctLines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }, font)
        }
        var set = layout(fontSize)
        // Narrow videos: shrink the text so the box fits across.
        let widest = (set.widths.max() ?? 0) + fontSize * 1.2
        if widest > videoSize.width * 0.92 {
            fontSize = max(8, (fontSize * videoSize.width * 0.92 / widest).rounded(.down))
            set = layout(fontSize)
        }

        let padX = (fontSize * 0.6).rounded(), padY = (fontSize * 0.32).rounded()
        let lineHeight = (fontSize * 1.22).rounded()
        let width = Int(((set.widths.max() ?? 0) + padX * 2).rounded(.up))
        let height = Int(lineHeight * CGFloat(lines.count) + padY * 2)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: screenColors, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let box = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = fontSize * 0.38
        context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.8))
        context.fillPath()

        // Lines from the top down, each centered; the baseline sits a little below the
        // middle of its line.
        let ascent = set.font.ascender, descent = -set.font.descender
        for (index, line) in set.lines.enumerated() {
            let top = CGFloat(height) - padY - lineHeight * CGFloat(index)
            let baseline = top - (lineHeight - (ascent + descent)) / 2 - ascent
            context.textPosition = CGPoint(x: ((CGFloat(width) - set.widths[index]) / 2).rounded(), y: baseline.rounded())
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }
}
