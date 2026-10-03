import CoreImage
import Foundation

/// How pointer effects look in an exported video.
public struct PointerEffectStyle: Codable, Equatable, Sendable {
    public enum Tint: String, Codable, CaseIterable, Identifiable, Sendable {
        case yellow, blue, pink, green, red, white
        public var id: Self { self }
        public var label: String { rawValue.capitalized }
        public var rgb: (r: Double, g: Double, b: Double) {
            switch self {
            case .yellow: (1.00, 0.78, 0.00)
            case .blue: (0.20, 0.55, 1.00)
            case .pink: (1.00, 0.32, 0.62)
            case .green: (0.20, 0.80, 0.45)
            case .red: (1.00, 0.30, 0.25)
            case .white: (1.00, 1.00, 1.00)
            }
        }
    }

    public enum Size: String, Codable, CaseIterable, Identifiable, Sendable {
        case small, medium, large
        public var id: Self { self }
        public var label: String {
            switch self {
            case .small: "S"
            case .medium: "M"
            case .large: "L"
            }
        }
        /// Highlight radius in screen points (the arrow pointer is about 20 points tall).
        var radius: Double {
            switch self {
            case .small: 16
            case .medium: 22
            case .large: 30
            }
        }
    }

    /// A soft circle that follows the pointer.
    public var highlight = true
    /// Fade the circle out when the pointer stops, and back in when it moves.
    public var fadeWhenStill = true
    /// A ring that grows out from every click.
    public var clicks = true
    /// A mouse click sound at every click, in exports. Off unless chosen, since it changes
    /// the audio.
    public var clickSounds = false
    public var tint: Tint = .yellow
    public var size: Size = .medium
    /// Zoom in toward clicks (see `ClickZoom`). Off unless chosen, so exports don't
    /// start moving on their own.
    public var zoom: Zoom = .off

    public init() {}

    // Tolerate settings saved by older versions that lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PointerEffectStyle()
        highlight = try c.decodeIfPresent(Bool.self, forKey: .highlight) ?? d.highlight
        fadeWhenStill = try c.decodeIfPresent(Bool.self, forKey: .fadeWhenStill) ?? d.fadeWhenStill
        clicks = try c.decodeIfPresent(Bool.self, forKey: .clicks) ?? d.clicks
        clickSounds = try c.decodeIfPresent(Bool.self, forKey: .clickSounds) ?? d.clickSounds
        tint = try c.decodeIfPresent(Tint.self, forKey: .tint) ?? d.tint
        size = try c.decodeIfPresent(Size.self, forKey: .size) ?? d.size
        zoom = try c.decodeIfPresent(Zoom.self, forKey: .zoom) ?? d.zoom
    }
}

/// Draws pointer effects onto video frames: the highlight that follows the pointer,
/// tightens over links and buttons, and gives a little when pressed, and the rings
/// that grow out from clicks. Shared by export and the review window's preview.
public final class PointerRenderer: @unchecked Sendable {
    private let track: PointerTrack
    private let style: PointerEffectStyle
    private let clicks: [PointerTrack.Click]
    /// Highlight radius in pixels.
    private let radius: Double
    private let color: (r: Double, g: Double, b: Double)
    /// How visible the highlight is (moving vs. still), how much it's over a link, and
    /// how pressed it is, sampled on a fine grid so changes ease in and out smoothly.
    private let activity: Envelope
    private let hand: Envelope
    private let press: Envelope

    static let clickLife = 0.55

    /// - Parameter videoSize: The video's size in pixels.
    public init?(track: PointerTrack, style: PointerEffectStyle, videoSize: CGSize) {
        guard style.highlight || style.clicks, !track.samples.isEmpty, videoSize.height > 0 else { return nil }
        self.track = track
        self.style = style
        clicks = track.clicks.filter(\.isEnabled).sorted { $0.time < $1.time }
        radius = style.size.radius * track.pointSize * videoSize.height
        color = style.tint.rgb

        let samples = track.samples
        let end = max(samples.last?.time ?? 0, clicks.last.map { $0.time + $0.duration } ?? 0) + 2
        // Moving at least half a point between samples counts as moving.
        let pointsPerX = Double(videoSize.width / videoSize.height) / track.pointSize
        let pointsPerY = 1 / track.pointSize
        let clicks = clicks

        var index = 0
        func segment(_ t: Double) -> Int {
            while index + 1 < samples.count, samples[index + 1].time <= t { index += 1 }
            return index
        }
        func isPressed(_ t: Double) -> Bool {
            clicks.contains { t >= $0.time && t <= $0.time + max($0.duration, 0.08) }
        }

        index = 0
        activity = Envelope(duration: end, attack: 0.10, hold: 0.6, release: 0.4) { t in
            if isPressed(t) { return true }
            let i = segment(t)
            guard i + 1 < samples.count, t >= samples[i].time else { return false }
            let a = samples[i], b = samples[i + 1]
            return hypot((b.x - a.x) * pointsPerX, (b.y - a.y) * pointsPerY) > 0.5
        }
        index = 0
        hand = Envelope(duration: end, attack: 0.12, hold: 0.05, release: 0.15) { t in
            samples[segment(t)].isHand
        }
        press = Envelope(duration: end, attack: 0.05, hold: 0, release: 0.15, target: isPressed)
    }

    /// Whether anything is drawn at `time`, so untouched frames can be skipped.
    public func isActive(at time: Double) -> Bool {
        highlightStrength(at: time) > 0.002 || activeClicks(at: time).contains { _ in true }
    }

    public func apply(to frame: CIImage, at time: Double) -> CIImage {
        // Core Image normally blends in linear light, where a see-through yellow over white
        // turns peach. Blending in ordinary screen colors instead, like a design tool,
        // keeps the colors true.
        let extent = frame.extent
        var output = frame.matchedFromWorkingSpace(to: Self.screenColors) ?? frame

        if let (point, _) = track.position(at: time) {
            let strength = highlightStrength(at: time)
            if strength > 0.002 {
                let center = pixel(point, in: extent)
                let h = hand.value(at: time)
                let p = press.value(at: time)
                // Over a link: smaller and stronger, as if focusing. Pressed: gives a little.
                let r = radius * (1 - 0.18 * h) * (1 - 0.12 * p)
                let fill = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: center.x, y: center.y),
                    "inputRadius0": r * 0.45,
                    "inputRadius1": r,
                    "inputColor0": tint(alpha: (0.45 + 0.12 * h) * strength),
                    "inputColor1": tint(alpha: 0),
                ])!.outputImage!.cropped(to: bounds(center, r + 2))
                output = fill.composited(over: output)
                let width = max(1.5, r * 0.08)
                output = ring(center, radius: r * 0.94 + width, width: 1.2, white: 0, alpha: 0.16 * strength)
                    .composited(over: output)
                output = ring(center, radius: r * 0.94, width: width, alpha: (0.7 + 0.3 * h) * strength)
                    .composited(over: output)
            }
        }

        for click in activeClicks(at: time) {
            output = drawClick(click, age: time - click.time, in: extent, over: output)
        }
        return (output.matchedToWorkingSpace(from: Self.screenColors) ?? output).cropped(to: extent)
    }

    private static let screenColors = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Colors given in this space pass through unchanged, so they stay screen colors.
    private static let passThrough = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    // MARK: - Pieces

    private func highlightStrength(at time: Double) -> Double {
        guard style.highlight, let (point, _) = track.position(at: time),
              time >= (track.samples.first?.time ?? 0), isVisible(point) else { return 0 }
        return style.fadeWhenStill ? activity.value(at: time) : 1
    }

    private func activeClicks(at time: Double) -> [PointerTrack.Click] {
        guard style.clicks else { return [] }
        return clicks.filter { time >= $0.time && time < $0.time + Self.clickLife + 0.12 && isVisible(CGPoint(x: $0.x, y: $0.y)) }
    }

    /// On the video and not behind the camera circle, where the real pointer is hidden.
    private func isVisible(_ point: CGPoint) -> Bool {
        guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return false }
        if let circle = track.cameraCircle, circle.width > 0, circle.height > 0 {
            let dx = (point.x - circle.midX) / (circle.width / 2)
            let dy = (point.y - circle.midY) / (circle.height / 2)
            if dx * dx + dy * dy <= 1 { return false }
        }
        return true
    }

    /// A ring that grows and fades. Clicks on links get a bolder ring; right-clicks get
    /// two, so they read differently.
    private func drawClick(_ click: PointerTrack.Click, age: Double, in extent: CGRect, over frame: CIImage) -> CIImage {
        let center = pixel(CGPoint(x: click.x, y: click.y), in: extent)
        var output = frame

        // A quick dot where the click landed.
        let dotLife = 0.3
        if age < dotLife {
            let u = age / dotLife
            let dot = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: center.x, y: center.y),
                "inputRadius0": radius * 0.22 * (1 - 0.3 * u),
                "inputRadius1": radius * 0.34 * (1 - 0.3 * u),
                "inputColor0": tint(alpha: 0.75 * (1 - u)),
                "inputColor1": tint(alpha: 0),
            ])!.outputImage!.cropped(to: bounds(center, radius * 0.4))
            output = dot.composited(over: output)
        }

        let delays: [Double] = click.button == .right ? [0, 0.12] : [0]
        for delay in delays {
            let u = (age - delay) / Self.clickLife
            guard u >= 0, u < 1 else { continue }
            let grow = 1 - pow(1 - u, 3)
            let r = radius * (0.45 + (click.button == .right ? 0.8 : 1.05) * grow)
            let width = max(2, radius * (click.isHand ? 0.2 : 0.14) * (1 - 0.45 * u))
            let alpha = pow(1 - u, 1.4)
            // A faint dark edge keeps the ring visible on white backgrounds.
            output = ring(center, radius: r, width: width + 2.5, white: 0, alpha: alpha * 0.2).composited(over: output)
            output = ring(center, radius: r, width: width, alpha: alpha).composited(over: output)
        }
        return output
    }

    private func ring(_ center: CGPoint, radius r: Double, width: Double, white: Double? = nil, alpha: Double) -> CIImage {
        let outer = disc(center, r + width / 2)
        let inner = disc(center, max(r - width / 2, 0))
        let mask = outer.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
        let rgb = white.map { (r: $0, g: $0, b: $0) } ?? color
        return mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            "inputBiasVector": CIVector(x: rgb.r, y: rgb.g, z: rgb.b, w: 0),
        ])
    }

    /// An anti-aliased white disc.
    private func disc(_ center: CGPoint, _ r: Double) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: center.x, y: center.y),
            "inputRadius0": max(r - 0.75, 0),
            "inputRadius1": r + 0.75,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1, colorSpace: Self.passThrough)!,
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0, colorSpace: Self.passThrough)!,
        ])!.outputImage!.cropped(to: bounds(center, r + 1))
    }

    private func tint(alpha: Double) -> CIColor {
        CIColor(red: color.r, green: color.g, blue: color.b, alpha: alpha, colorSpace: Self.passThrough)!
    }

    private func pixel(_ point: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + point.y * extent.height)
    }

    private func bounds(_ center: CGPoint, _ r: Double) -> CGRect {
        CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }
}

/// A value that eases toward 1 while `target` is true and back to 0 after it stops,
/// precomputed on a fine grid so any moment can be looked up instantly.
struct Envelope {
    private let step = 1.0 / 120
    private let values: [Float]

    /// - Parameters:
    ///   - attack: Seconds to rise from 0 to 1.
    ///   - hold: Seconds to stay up after `target` turns false.
    ///   - release: Seconds to fall from 1 to 0.
    init(duration: Double, attack: Double, hold: Double, release: Double, target: (Double) -> Bool) {
        let count = max(1, Int(duration / step) + 2)
        var values = [Float](repeating: 0, count: count)
        var level = 0.0
        var holdLeft = 0.0
        for i in 0..<count {
            let t = Double(i) * step
            if target(t) {
                level = min(1, level + step / max(attack, 0.001))
                holdLeft = hold
            } else if holdLeft > 0 {
                holdLeft -= step
            } else {
                level = max(0, level - step / max(release, 0.001))
            }
            values[i] = Float(level)
        }
        self.values = values
    }

    /// Smoothed so the start and end of each change ease rather than snap.
    func value(at time: Double) -> Double {
        let position = max(0, time / step)
        let i = min(Int(position), values.count - 1)
        let j = min(i + 1, values.count - 1)
        let f = position - Double(i)
        let linear = Double(values[i]) * (1 - f) + Double(values[j]) * f
        return linear * linear * (3 - 2 * linear)
    }
}
