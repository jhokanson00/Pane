import CoreImage
import XCTest
@testable import PaneKit

final class ClickZoomTests: XCTestCase {
    /// A pointer that rests at `start`, glides to `end` between `moveFrom` and `moveTo`,
    /// then rests again, sampled 60 times a second for 12 s.
    private func track(clicks: [(Double, CGPoint)], start: CGPoint = CGPoint(x: 0.3, y: 0.4),
                       end: CGPoint = CGPoint(x: 0.3, y: 0.4), moveFrom: Double = 0, moveTo: Double = 0,
                       camera: CGRect? = nil) -> PointerTrack {
        let samples = stride(from: 0.0, through: 12, by: 1.0 / 60).map { t in
            let u = moveTo > moveFrom ? min(max((t - moveFrom) / (moveTo - moveFrom), 0), 1) : 0
            return PointerTrack.Sample(time: t, x: start.x + (end.x - start.x) * u,
                                       y: start.y + (end.y - start.y) * u, isHand: false)
        }
        return PointerTrack(
            samples: samples,
            clicks: clicks.map { .init(time: $0.0, x: $0.1.x, y: $0.1.y, button: .left, isHand: false, duration: 0.08) },
            pointSize: 1.0 / 900, cameraCircle: camera)
    }

    func testNoZoomWithoutClicks() {
        XCTAssertNil(ClickZoom(track: track(clicks: []), zoom: .strong))
        XCTAssertNil(ClickZoom(track: track(clicks: [(3, CGPoint(x: 0.3, y: 0.4))]), zoom: .off))
        // Hidden clicks, and clicks off the video, aren't zoomed toward.
        var hidden = track(clicks: [(3, CGPoint(x: 0.3, y: 0.4))])
        hidden.clicks[0].isEnabled = false
        XCTAssertNil(ClickZoom(track: hidden, zoom: .strong))
        XCTAssertNil(ClickZoom(track: track(clicks: [(3, CGPoint(x: 0.9, y: 1.28))]), zoom: .strong))
    }

    func testEasesInBeforeTheClickAndOutAfterIt() throws {
        let zoom = try XCTUnwrap(ClickZoom(track: track(clicks: [(5, CGPoint(x: 0.3, y: 0.4))]), zoom: .subtle))
        XCTAssertEqual(zoom.scale(at: 4.5), 1, "still out before the lead-in")
        XCTAssertEqual(zoom.scale(at: 4.6), 1, accuracy: 1e-9, "starts 0.4 s before the click")
        XCTAssertGreaterThan(zoom.scale(at: 5), 1.3, "mostly in at the click")
        XCTAssertEqual(zoom.scale(at: 5.2), 1.4, accuracy: 1e-9)
        XCTAssertEqual(zoom.scale(at: 5.8), 1.4, accuracy: 1e-9, "holds 0.8 s after the click")
        XCTAssertLessThan(zoom.scale(at: 6.2), 1.4)
        XCTAssertEqual(zoom.scale(at: 6.6), 1, accuracy: 1e-9, "out again")

        // Rises and falls steadily, with no sudden steps between 120 fps frames, and
        // starts and ends gently.
        var previous = zoom.scale(at: 4)
        var rising = true
        for t in stride(from: 4.0, through: 7, by: 1.0 / 120) {
            let s = zoom.scale(at: t)
            XCTAssertLessThan(abs(s - previous), 0.012, "at \(t)")
            if t > 5.2 { rising = false }
            if rising { XCTAssertGreaterThanOrEqual(s, previous - 1e-12) } else { XCTAssertLessThanOrEqual(s, previous + 1e-12) }
            previous = s
        }
        XCTAssertLessThan(zoom.scale(at: 4.6 + 1.0 / 30) - 1, 0.002, "eases in, no jolt on the first frame")
    }

    func testNearbyClicksShareOneStretch() throws {
        let p = CGPoint(x: 0.4, y: 0.5)
        let close = try XCTUnwrap(ClickZoom(track: track(clicks: [(2, p), (4, p), (6.4, p)]), zoom: .strong))
        XCTAssertEqual(close.stretches.count, 1)
        for t in stride(from: 2.2, through: 7.2, by: 0.05) {
            XCTAssertEqual(close.scale(at: t), 1.8, accuracy: 1e-9, "stays in between clicks, at \(t)")
        }

        let apart = try XCTUnwrap(ClickZoom(track: track(clicks: [(2, p), (5.5, p)]), zoom: .strong))
        XCTAssertEqual(apart.stretches.count, 2)
        XCTAssertEqual(apart.scale(at: 4.3), 1, accuracy: 1e-9, "zoomed out between far-apart clicks")
    }

    func testAimsAtTheClickAndFollowsThePointerSmoothly() throws {
        // Clicks at the middle, then the pointer drifts right while zoomed, and clicks there.
        let zoom = try XCTUnwrap(ClickZoom(
            track: track(clicks: [(3, CGPoint(x: 0.5, y: 0.5)), (5, CGPoint(x: 0.62, y: 0.55))],
                         start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.62, y: 0.55), moveFrom: 3.5, moveTo: 4.2),
            zoom: .subtle))
        let atClick = zoom.viewRect(at: 3.2)
        XCTAssertEqual(atClick.midX, 0.5, accuracy: 0.001)
        XCTAssertEqual(atClick.midY, 0.5, accuracy: 0.001)

        let atSecond = zoom.viewRect(at: 5)
        XCTAssertEqual(atSecond.midX, 0.62, accuracy: 0.01, "caught up with the pointer by the next click")
        XCTAssertEqual(atSecond.midY, 0.55, accuracy: 0.01)

        // The view glides: on a 1600-px-wide video it moves a few pixels between 60 fps
        // frames at most, and it gathers and loses speed gradually, with no jolts.
        var previous = zoom.viewRect(at: 2)
        var previousSpeed = 0.0, previousChange = 0.0
        var fastest = 0.0, sharpest = 0.0, jolt = 0.0
        for t in stride(from: 2.0, through: 8, by: 1.0 / 60) {
            let rect = zoom.viewRect(at: t)
            let speed = hypot(rect.midX - previous.midX, rect.midY - previous.midY) * 1600
            let change = speed - previousSpeed
            fastest = max(fastest, speed)
            sharpest = max(sharpest, abs(change))
            jolt = max(jolt, abs(change - previousChange))
            previous = rect
            previousSpeed = speed
            previousChange = change
        }
        XCTAssertLessThan(fastest, 12)
        XCTAssertLessThan(sharpest, 1.5)
        XCTAssertLessThan(jolt, 0.5)
    }

    func testSmallMovesDontShakeTheView() throws {
        // A 3-px jiggle around the click while zoomed in.
        var jiggle = track(clicks: [(3, CGPoint(x: 0.5, y: 0.5))], start: CGPoint(x: 0.5, y: 0.5))
        jiggle.samples = jiggle.samples.map { s in
            var s = s
            s.x = 0.5 + 0.002 * sin(s.time * 40)
            return s
        }
        let zoom = try XCTUnwrap(ClickZoom(track: jiggle, zoom: .strong))
        let centers = stride(from: 3.0, through: 3.8, by: 1.0 / 60).map { zoom.viewRect(at: $0).midX }
        XCTAssertLessThan((centers.max()! - centers.min()!) * 1600, 0.5)
    }

    func testViewStaysInsideTheVideo() throws {
        let corner = CGPoint(x: 0.02, y: 0.98)
        let zoom = try XCTUnwrap(ClickZoom(track: track(clicks: [(3, corner)], start: corner, end: CGPoint(x: 1.2, y: -0.1),
                                                        moveFrom: 3.2, moveTo: 3.6), zoom: .strong))
        let full = zoom.viewRect(at: 3.3)
        XCTAssertEqual(full.minX, 0, accuracy: 1e-6, "pinned to the left edge")
        XCTAssertEqual(full.maxY, 1, accuracy: 1e-6, "pinned to the top edge")
        XCTAssertEqual(full.width, 1 / 1.8, accuracy: 1e-9)
        for t in stride(from: 0.0, through: 6, by: 1.0 / 60) {
            let rect = zoom.viewRect(at: t)
            XCTAssertGreaterThanOrEqual(rect.minX, -1e-6)
            XCTAssertGreaterThanOrEqual(rect.minY, -1e-6)
            XCTAssertLessThanOrEqual(rect.maxX, 1 + 1e-6)
            XCTAssertLessThanOrEqual(rect.maxY, 1 + 1e-6)
        }
    }

    func testOldSavedStylesLoadWithZoomOff() throws {
        let old = Data(#"{"highlight":true,"fadeWhenStill":false,"clicks":true,"tint":"blue","size":"large"}"#.utf8)
        let style = try JSONDecoder().decode(PointerEffectStyle.self, from: old)
        XCTAssertEqual(style.zoom, .off)
        XCTAssertEqual(style.tint, .blue)

        var strong = PointerEffectStyle()
        strong.zoom = .strong
        XCTAssertEqual(try JSONDecoder().decode(PointerEffectStyle.self, from: JSONEncoder().encode(strong)).zoom, .strong)
    }

    func testZoomsFramesButKeepsTheCameraCircle() throws {
        let size = CGSize(width: 160, height: 90)
        let camera = CGRect(x: 0.75, y: 0.05, width: 0.2 * 9 / 16, height: 0.2)
        let effect = try XCTUnwrap(ClickZoomEffect(track: track(clicks: [(3, CGPoint(x: 0.3, y: 0.4))], camera: camera),
                                                   zoom: .strong))
        XCTAssertFalse(effect.isActive(at: 1))
        XCTAssertTrue(effect.isActive(at: 3.5))

        // A left-to-right gradient, so zooming changes what's under each pixel.
        let frame = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 160, y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])!.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
        let output = effect.apply(to: frame, at: 3.5)
        XCTAssertEqual(output.extent, frame.extent)

        let context = CIContext()
        func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [UInt8] {
            var value = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &value, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return value
        }
        // Zoomed toward the left: the middle of the frame now shows darker, left-side pixels.
        XCTAssertLessThan(Int(pixel(output, 80, 45)[0]), Int(pixel(frame, 80, 45)[0]) - 20)
        // No see-through or dark rim at the edges.
        for (x, y) in [(0, 0), (159, 0), (0, 89), (159, 89)] {
            XCTAssertEqual(pixel(output, x, y)[3], 255)
        }
        XCTAssertGreaterThan(pixel(output, 159, 45)[0], 100, "right edge isn't black")
        // The camera circle is the original, unzoomed picture.
        let cx = Int(camera.midX * 160), cy = Int(camera.midY * 90)
        XCTAssertEqual(Double(pixel(output, cx, cy)[0]), Double(pixel(frame, cx, cy)[0]), accuracy: 1)
    }

    func testCameraNeverShowsEnlarged() throws {
        // A red "camera" in the bottom-left corner of a white frame, and clicks right
        // next to it, so the zoomed view takes in that corner.
        let width = 320, height = 180
        let camera = CGRect(x: 0.03, y: 0.05, width: 0.3 * 180 / 320, height: 0.3)
        let center = CGPoint(x: camera.midX * 320, y: camera.midY * 180)
        let radius = camera.height * 180 / 2
        let red = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: center.x, y: center.y), "inputRadius0": radius - 0.5, "inputRadius1": radius + 0.5,
            "inputColor0": CIColor(red: 1, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 0, blue: 0, alpha: 0),
        ])!.outputImage!
        let frame = red.composited(over: CIImage(color: .white)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let effect = try XCTUnwrap(ClickZoomEffect(
            track: track(clicks: [(3, CGPoint(x: 0.2, y: 0.3))], start: CGPoint(x: 0.2, y: 0.3), camera: camera),
            zoom: .strong))

        for time in [2.75, 2.9, 3.0, 3.5, 4.2] {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            CIContext().render(effect.apply(to: frame, at: time), toBitmap: &pixels, rowBytes: width * 4,
                               bounds: frame.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            var stray = 0
            for y in 0..<height {
                for x in 0..<width {
                    let i = ((height - 1 - y) * width + x) * 4
                    let isRed = pixels[i] > 200 && pixels[i + 1] < 120
                    if isRed && hypot(Double(x) + 0.5 - center.x, Double(y) + 0.5 - center.y) > radius + 1.5 { stray += 1 }
                }
            }
            XCTAssertEqual(stray, 0, "red outside the camera circle at \(time)")
        }
    }
}
