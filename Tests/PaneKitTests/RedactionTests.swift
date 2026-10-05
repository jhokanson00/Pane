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
}
