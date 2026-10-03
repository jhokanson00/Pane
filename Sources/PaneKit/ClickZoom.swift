import CoreImage
import Foundation

extension PointerEffectStyle {
    /// How far the video zooms in toward clicks.
    public enum Zoom: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, subtle, strong
        public var id: Self { self }
        public var label: String { rawValue.capitalized }
        /// How much bigger everything looks when fully zoomed in.
        public var scale: Double {
            switch self {
            case .off: 1
            case .subtle: 1.4
            case .strong: 1.8
            }
        }
    }
}

/// When and where the video zooms in toward clicks, like a camera operator would: it
/// starts moving in just before a click, stays in while clicks keep coming, follows
/// the pointer calmly while in, and eases back out after the last one. Times are
/// seconds into the video; points and rectangles are normalized, bottom-left origin.
public struct ClickZoom: Sendable {
    /// One zoomed-in stretch, from its first click to its last.
    public struct Stretch: Equatable, Sendable {
        public var firstClick: Double
        public var lastClick: Double
    }

    /// The zoom starts moving in this long before a click, so it's mostly in by the
    /// time the click happens instead of reacting after it.
    static let lead = 0.4
    /// How long moving in takes.
    static let zoomIn = 0.6
    /// How long the view stays in after the last click of a stretch.
    static let hold = 0.8
    /// How long moving back out takes.
    static let zoomOut = 0.8
    /// Clicks closer together than this share one stretch, rather than zooming out
    /// and straight back in, which looks restless.
    static let mergeGap = 2.5
    /// While zoomed in, the view starts heading for the next click this long before it.
    static let aimLead = 0.6
    /// How quickly the view catches up with the pointer, in seconds. Slow enough that
    /// small movements and hand tremor don't shake the picture.
    static let followTime = 0.3
    /// The pointer can wander this fraction of the half-view from the view's aim
    /// before the view starts following, so reading and small moves keep it still.
    static let slack = 0.35

    public let stretches: [Stretch]
    /// Full zoom, such as 1.4 for 1.4×.
    public let fullScale: Double
    /// Where the view aims, sampled on a fine grid and smoothed so it never jumps.
    private let focusX: [Float]
    private let focusY: [Float]
    private static let step = 1.0 / 120

    /// Nil when there's nothing to zoom toward: zoom off, or no clicks shown on the video.
    public init?(track: PointerTrack, zoom: PointerEffectStyle.Zoom) {
        // Clicks off the video, such as on another screen or the menu bar outside a
        // window recording, have nothing to zoom toward.
        let clicks = track.clicks
            .filter { $0.isEnabled && (0...1).contains($0.x) && (0...1).contains($0.y) }
            .sorted { $0.time < $1.time }
        guard zoom != .off, !clicks.isEmpty else { return nil }
        fullScale = zoom.scale

        var stretches: [Stretch] = []
        for click in clicks {
            if let last = stretches.last, click.time - last.lastClick <= Self.mergeGap {
                stretches[stretches.count - 1].lastClick = click.time
            } else {
                stretches.append(Stretch(firstClick: click.time, lastClick: click.time))
            }
        }
        self.stretches = stretches

        // Follow the pointer with a critically damped spring, so the view speeds up and
        // slows down smoothly and never overshoots. Aims are kept where the fully zoomed
        // view still fits inside the video, so the view eases to a stop at the edges
        // instead of bumping into them. While zoomed out the aim doesn't show, so it
        // simply sits on the pointer, ready for the next zoom.
        let end = max(track.samples.last?.time ?? 0, stretches.last!.lastClick + Self.hold + Self.zoomOut) + 1
        let count = Int(end / Self.step) + 2
        var xs = [Float](repeating: 0.5, count: count)
        var ys = [Float](repeating: 0.5, count: count)
        let half = 0.5 / fullScale
        func inside(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, half), 1 - half), y: min(max(p.y, half), 1 - half))
        }
        let slack = Self.slack * half
        var aim = CGPoint(x: 0.5, y: 0.5)
        var followX = Follower(aim.x), followY = Follower(aim.y)
        var next = 0
        for i in 0..<count {
            let t = Double(i) * Self.step
            while next < clicks.count, clicks[next].time < t { next += 1 }
            // Just before a click, head for where it lands, so the view arrives with it.
            if next < clicks.count, clicks[next].time - t <= Self.aimLead {
                aim = inside(CGPoint(x: clicks[next].x, y: clicks[next].y))
            } else {
                let goal = inside(track.position(at: t)?.point ?? aim)
                aim.x = min(max(aim.x, goal.x - slack), goal.x + slack)
                aim.y = min(max(aim.y, goal.y - slack), goal.y + slack)
            }
            if Self.amount(at: t, stretches: stretches) <= 0 {
                followX = Follower(aim.x)
                followY = Follower(aim.y)
            } else {
                followX.move(toward: aim.x)
                followY.move(toward: aim.y)
            }
            let focus = inside(CGPoint(x: followX.position, y: followY.position))
            xs[i] = Float(focus.x)
            ys[i] = Float(focus.y)
        }
        focusX = xs
        focusY = ys
    }

    /// How far in the zoom is, from 0 (not zoomed) to 1 (fully in).
    public func amount(at time: Double) -> Double {
        Self.amount(at: time, stretches: stretches)
    }

    /// How much bigger everything looks at `time`: 1 when not zoomed.
    public func scale(at time: Double) -> Double {
        // Equal steps in scale look uneven; equal ratios look steady.
        pow(fullScale, amount(at: time))
    }

    /// The part of the video shown at `time`, always inside the video.
    public func viewRect(at time: Double) -> CGRect {
        let scale = scale(at: time)
        let half = 0.5 / scale
        // At full zoom the aim is the view's center. On the way in and out, the view
        // grows and shrinks around one point that stays put on screen, so it never
        // needs pushing back inside the video, which would make it lurch.
        let progress = fullScale > 1 ? (1 - 1 / scale) / (1 - 1 / fullScale) : 0
        let focus = focus(at: time)
        return CGRect(x: 0.5 + (focus.x - 0.5) * progress - half, y: 0.5 + (focus.y - 0.5) * progress - half,
                      width: 2 * half, height: 2 * half)
    }

    /// Where the fully zoomed view would be centered at `time`.
    func focus(at time: Double) -> CGPoint {
        let position = max(0, time / Self.step)
        let i = min(Int(position), focusX.count - 1)
        let j = min(i + 1, focusX.count - 1)
        let f = position - Double(i)
        return CGPoint(x: Double(focusX[i]) * (1 - f) + Double(focusX[j]) * f,
                       y: Double(focusY[i]) * (1 - f) + Double(focusY[j]) * f)
    }

    private static func amount(at time: Double, stretches: [Stretch]) -> Double {
        var amount = 0.0
        for stretch in stretches {
            let start = stretch.firstClick - lead
            let outStart = stretch.lastClick + hold
            if time <= start || time >= outStart + zoomOut { continue }
            let value: Double
            if time < start + zoomIn {
                value = ease((time - start) / zoomIn)
            } else if time <= outStart {
                value = 1
            } else {
                value = 1 - ease((time - outStart) / zoomOut)
            }
            amount = max(amount, value)
        }
        return amount
    }

    /// Starts and ends with no speed and no sudden change in speed.
    static func ease(_ x: Double) -> Double {
        let u = min(max(x, 0), 1)
        return u * u * u * (u * (u * 6 - 15) + 10)
    }

    /// Follows a moving target along one axis with two critically damped springs in a
    /// row. One spring alone changes its pull the instant the target jumps, which shows
    /// as a small jolt; the second smooths that out, so the view gathers speed gently.
    private struct Follower {
        private var middle: Double
        private var middleVelocity = 0.0
        private(set) var position: Double
        private var velocity = 0.0

        init(_ start: Double) {
            middle = start
            position = start
        }

        mutating func move(toward target: Double) {
            middle = Self.smoothDamp(middle, toward: target, velocity: &middleVelocity)
            position = Self.smoothDamp(position, toward: middle, velocity: &velocity)
        }

        /// One step of a critically damped spring (the well-known "smooth damp"
        /// approximation, stable at any step size).
        private static func smoothDamp(_ current: Double, toward target: Double, velocity: inout Double) -> Double {
            let omega = 4 / ClickZoom.followTime
            let x = omega * ClickZoom.step
            let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
            let change = current - target
            let temp = (velocity + omega * change) * ClickZoom.step
            velocity = (velocity - omega * temp) * decay
            return target + (change + temp) * decay
        }
    }
}

/// Zooms the video toward clicks. It runs after the blurs and pointer effects, so they
/// grow with the picture. A camera circle drawn into the video stays where it is, at
/// its normal size, since a camera that swells and slides around is distracting. Near
/// the camera, the unzoomed picture shows through around it instead.
public final class ClickZoomEffect: FrameEffect {
    public let zoom: ClickZoom
    private let cameraCircle: CGRect?

    /// - Parameters:
    ///   - track: Its camera circle, if any, is kept still and unzoomed. Leave it out
    ///     when the camera is on its own layer.
    public init?(track: PointerTrack, zoom: PointerEffectStyle.Zoom) {
        guard let curve = ClickZoom(track: track, zoom: zoom) else { return nil }
        self.zoom = curve
        cameraCircle = track.cameraCircle
    }

    public func isActive(at time: Double) -> Bool {
        zoom.scale(at: time) > 1.0005
    }

    public func apply(to frame: CIImage, at time: Double) -> CIImage {
        let extent = frame.extent
        let view = zoom.viewRect(at: time)
        let scale = 1 / view.width
        let shown = CGRect(x: extent.minX + view.minX * extent.width, y: extent.minY + view.minY * extent.height,
                           width: view.width * extent.width, height: view.height * extent.height)
        // Lanczos keeps enlarged text crisper than plain smoothing. Extending the edge
        // pixels outward means the enlarged picture never has a see-through or dark rim.
        let enlarged = frame.clampedToExtent()
            .cropped(to: shown.insetBy(dx: -8, dy: -8))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            .transformed(by: CGAffineTransform(translationX: extent.minX - shown.minX * scale,
                                               y: extent.minY - shown.minY * scale))
            .cropped(to: extent)

        guard let circle = cameraCircle, circle.width > 0, circle.height > 0 else { return enlarged }
        let shortSide = min(extent.width, extent.height)
        let center = CGPoint(x: extent.minX + circle.midX * extent.width, y: extent.minY + circle.midY * extent.height)
        // The circle including its border, as in the recording.
        let outer = circle.height * extent.height / 2

        // A fresh soft shadow under where the camera goes, drawn the way the recorder
        // draws it. Bringing back the old one would bring back the unzoomed picture
        // around the circle too, which shows as a ring.
        var output = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: center.x, y: center.y - shortSide * 0.006),
            "inputRadius0": outer,
            "inputRadius1": outer + shortSide * 0.025,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.35),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])!.outputImage!
            .cropped(to: CGRect(x: center.x, y: center.y, width: 0, height: 0).insetBy(dx: -outer - shortSide * 0.04,
                                                                                       dy: -outer - shortSide * 0.04))
            .composited(over: enlarged)

        // When the view takes in the camera's corner, the zoomed picture has its own,
        // bigger copy of the camera and its shadow. Cover that with the unzoomed picture,
        // fading at the edge so no seam shows.
        let reach = (outer + shortSide * 0.033) * scale
        let zoomedCenter = CGPoint(x: extent.minX + (center.x - shown.minX) * scale,
                                   y: extent.minY + (center.y - shown.minY) * scale)
        if extent.intersects(CGRect(x: zoomedCenter.x - reach, y: zoomedCenter.y - reach, width: 2 * reach, height: 2 * reach)) {
            output = frame.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: Self.disc(zoomedCenter, reach, feather: shortSide * 0.012 * scale),
            ])
        }

        // The camera itself, from the unzoomed frame.
        let camera = frame.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: Self.disc(center, outer + 0.5, feather: 1),
        ]).cropped(to: CGRect(x: center.x - outer - 2, y: center.y - outer - 2, width: 2 * outer + 4, height: 2 * outer + 4))
        return camera.composited(over: output).cropped(to: extent)
    }

    /// A white disc that fades out over `feather` pixels past `radius`.
    private static func disc(_ center: CGPoint, _ radius: Double, feather: Double) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: center.x, y: center.y),
            "inputRadius0": radius,
            "inputRadius1": radius + feather,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])!.outputImage!
    }
}
