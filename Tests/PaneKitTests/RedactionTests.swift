import CoreImage
import XCTest
@testable import PaneKit

final class RedactionTests: XCTestCase {
    /// Vertical black and white stripes, which any blur visibly averages to gray.
    private let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
        "inputColor0": CIColor.black, "inputColor1": CIColor.white, "inputWidth": 4,
    ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))

    private func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return rgba
    }

    func testCircleBlursInsideButNotTheBoxCorners() {
        let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let circle = Finding(kind: .manual, text: "", samples: [BoxSample(time: 0, rect: box)],
                             start: 0, end: 10, shape: .ellipse)
        let output = Redaction.apply(to: stripes, findings: [circle], at: 5)

        // The middle is averaged to a gray, where the stripes were pure black or white.
        let middle = pixel(output, 200, 200)[0]
        XCTAssertTrue((40...215).contains(middle), "middle is \(middle)")
        // The box's corners are outside the circle, so the stripes stay sharp there.
        for (x, y) in [(105.0, 105.0), (294.0, 105.0), (105.0, 294.0), (294.0, 294.0)] {
            XCTAssertEqual(pixel(output, x, y), pixel(stripes, x, y), "corner at \(x), \(y)")
        }
    }

    func testDrawnShapesStayOnForTheWholeVideo() {
        let box = Finding(kind: .manual, text: "", samples: [BoxSample(time: 3, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))],
                          start: 0, end: 10)
        XCTAssertEqual(box.coverRect(at: 0, aspect: 1), box.coverRect(at: 9.9, aspect: 1))
        XCTAssertNotNil(box.coverRect(at: 0, aspect: 1))
    }

    private func bitmap(_ image: CIImage) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        CIContext().render(image, toBitmap: &rgba, rowBytes: Int(image.extent.width) * 4, bounds: image.extent,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return rgba
    }

    /// Whatever is under a blur, the result is the same: nothing to compare guesses with.
    func testNothingUnderTheBlurShowsThrough() {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 400, y: 400),
            "inputColor0": CIColor(red: 0.9, green: 0.85, blue: 0.8), "inputColor1": CIColor(red: 0.3, green: 0.4, blue: 0.6),
        ])!.outputImage!.cropped(to: stripes.extent)
        let box = CGRect(x: 100, y: 150, width: 200, height: 40)
        let other = CGRect(x: 100, y: 196, width: 200, height: 40)
        // Different "text" in each box, inside its padding as text is: stripes, or a
        // solid color.
        func frame(_ inside: CIImage, _ nextDoor: CIImage) -> CIImage {
            inside.cropped(to: box.insetBy(dx: 8, dy: 8))
                .composited(over: nextDoor.cropped(to: other.insetBy(dx: 60, dy: 10)).composited(over: gradient))
        }
        let a = frame(stripes, stripes)
        let b = frame(CIImage(color: .red).cropped(to: stripes.extent), CIImage(color: .blue).cropped(to: stripes.extent))
        let normalized = { (rect: CGRect) in
            CGRect(x: rect.minX / 400, y: rect.minY / 400, width: rect.width / 400, height: rect.height / 400)
        }
        let areas: [(rect: CGRect, shape: BlurShape)] = [(normalized(box), .rectangle), (normalized(other), .ellipse)]
        let blurredA = bitmap(Redaction.apply(to: a, areas: areas))
        let blurredB = bitmap(Redaction.apply(to: b, areas: areas))
        let different = blurredA.indices.filter { blurredA[$0] != blurredB[$0] }.map { ($0 / 4) % 400 }
        XCTAssertTrue(different.isEmpty, "\(different.count) values differ, columns \(different.min() ?? 0)–\(different.max() ?? 0)")
        XCTAssertNotEqual(bitmap(a), bitmap(b))
    }
}
