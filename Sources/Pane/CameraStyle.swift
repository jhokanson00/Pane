import AppKit
import CoreImage
import SwiftUI

/// How the camera circle looks and where it sits in the video.
struct CameraStyle: Codable, Equatable {
    enum Corner: String, Codable, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: Self { self }
        var label: String {
            switch self {
            case .topLeft: "Top left"
            case .topRight: "Top right"
            case .bottomLeft: "Bottom left"
            case .bottomRight: "Bottom right"
            }
        }
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    enum Size: String, Codable, CaseIterable, Identifiable {
        case small, medium, large
        var id: Self { self }
        var label: String {
            switch self {
            case .small: "S"
            case .medium: "M"
            case .large: "L"
            }
        }
        /// Circle diameter as a fraction of the video's shorter side.
        var fraction: CGFloat {
            switch self {
            case .small: 0.22
            case .medium: 0.30
            case .large: 0.40
            }
        }
    }

    enum Background: String, Codable, CaseIterable, Identifiable {
        case none, blur, color, image
        var id: Self { self }
        var label: String {
            switch self {
            case .none: "None"
            case .blur: "Blur"
            case .color: "Color"
            case .image: "Image"
            }
        }
    }

    var corner: Corner = .bottomLeft
    var size: Size = .medium
    var background: Background = .none
    var backgroundColor = RGBA(r: 0.20, g: 0.27, b: 0.45)
    var backgroundImagePath: String?
    var borderEnabled = true
    var borderColor = RGBA.white
    var mirrored = true
    /// Show a matching bubble on your screen while recording, so you can see yourself.
    /// It's never captured; the circle in the video is drawn separately.
    var showBubbleWhileRecording = true

    init() {}

    // Tolerate settings saved by older versions that lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraStyle()
        corner = try c.decodeIfPresent(Corner.self, forKey: .corner) ?? d.corner
        size = try c.decodeIfPresent(Size.self, forKey: .size) ?? d.size
        background = try c.decodeIfPresent(Background.self, forKey: .background) ?? d.background
        backgroundColor = try c.decodeIfPresent(RGBA.self, forKey: .backgroundColor) ?? d.backgroundColor
        backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        borderEnabled = try c.decodeIfPresent(Bool.self, forKey: .borderEnabled) ?? d.borderEnabled
        borderColor = try c.decodeIfPresent(RGBA.self, forKey: .borderColor) ?? d.borderColor
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? d.mirrored
        showBubbleWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .showBubbleWhileRecording)
            ?? d.showBubbleWhileRecording
    }
}

struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1

    static let white = RGBA(r: 1, g: 1, b: 1)

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var ciColor: CIColor { CIColor(cgColor: cgColor) }
}

/// Where the circle lands on a canvas of a given size. Shared by the video compositor,
/// the on-screen bubble and the layout preview so all three agree.
struct OverlayLayout {
    let center: CGPoint
    let radius: CGFloat
    /// Border thickness (0 when the border is off).
    let ring: CGFloat

    /// - Parameter topLeftOrigin: true for SwiftUI coordinates, false for Core Image / AppKit.
    init(style: CameraStyle, canvas: CGSize, topLeftOrigin: Bool) {
        let shortSide = min(canvas.width, canvas.height)
        radius = shortSide * style.size.fraction / 2
        ring = style.borderEnabled ? max(2, radius * 0.05) : 0
        let inset = shortSide * 0.035 + ring + radius
        let x = style.corner.isLeft ? inset : canvas.width - inset
        let yFromTop = style.corner.isTop ? inset : canvas.height - inset
        center = CGPoint(x: x, y: topLeftOrigin ? yFromTop : canvas.height - yFromTop)
    }

    var outerDiameter: CGFloat { (radius + ring) * 2 }
}
