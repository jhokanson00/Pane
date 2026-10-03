// Draws Pane's app icon and writes Resources/AppIcon.icns.
// Run with: swift scripts/make-icon.swift
//
// The artwork fills the whole square; macOS masks it to the rounded app-icon shape.
import AppKit
import CoreGraphics

let canvas = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func makeContext(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon() -> CGImage {
    let ctx = makeContext(canvas)
    let full = CGRect(x: 0, y: 0, width: canvas, height: canvas)

    // Background: "Cloud", one flat, nearly neutral light gray.
    ctx.setFillColor(color(0xEDEEF2))
    ctx.fill(full)

    // Everything is drawn 20% larger than the 1024 grid below, about the center, so the
    // shapes read boldly at Dock size.
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 1.2, y: 1.2)
    ctx.translateBy(x: -512, y: -512)

    // The screen. Screen and dot are positioned so the pair sits centered.
    let screen = CGRect(x: 147, y: 341, width: 672, height: 470)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x1E2240, 0.34))
    // A white frame with the dark screen inset in it, so no dark edge peeks out
    // around the frame on the light background.
    ctx.addPath(roundedRect(screen, 64))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(roundedRect(screen.insetBy(dx: 34, dy: 34), 33))
    ctx.setFillColor(color(0x232A4D))
    ctx.fillPath()

    // The record button, overlapping the screen's corner.
    let dot = CGPoint(x: 731, y: 359)
    let radius: CGFloat = 137
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 32, color: color(0x1E2240, 0.38))
    ctx.addEllipse(in: CGRect(x: dot.x - radius - 27, y: dot.y - radius - 27,
                              width: (radius + 27) * 2, height: (radius + 27) * 2))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2))
    ctx.clip()
    let red = CGGradient(colorsSpace: srgb, colors: [color(0xFF6A6A), color(0xE11D2E)] as CFArray,
                         locations: [0, 1])!
    ctx.drawLinearGradient(red, start: CGPoint(x: dot.x, y: dot.y + radius),
                           end: CGPoint(x: dot.x, y: dot.y - radius), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func resized(_ image: CGImage, to size: Int) -> CGImage {
    let ctx = makeContext(size)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = drawIcon()
writePNG(master, to: root.appendingPathComponent("Resources/AppIcon.png"))
for points in [16, 32, 128, 256, 512] {
    writePNG(resized(master, to: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(resized(master, to: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
