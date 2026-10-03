import XCTest
@testable import PaneKit

final class MotionTrackerTests: XCTestCase {
    /// A light page with a few rows of dark "words" whose pattern differs on each row,
    /// shifted down and right by (dx, dy) pixels.
    func page(dx: Int = 0, dy: Int = 0) -> LumaPlane {
        let width = 400, height = 300
        var pixels = [UInt8](repeating: 240, count: width * height)
        for row in 0..<6 {
            for word in 0..<8 {
                let x0 = 20 + word * 45 + (row * 7 + word * 13) % 11
                let y0 = 20 + row * 45
                let w = 18 + (row * 5 + word * 3) % 17
                for y in y0..<(y0 + 14) {
                    for x in x0..<(x0 + w) where (x + y + row) % 4 != 0 {
                        let px = x + dx, py = y + dy
                        if px >= 0, px < width, py >= 0, py < height { pixels[py * width + px] = 30 }
                    }
                }
            }
        }
        return LumaPlane(time: 0, width: width, height: height, pixels: pixels)
    }

    func testFindsSmallMoves() throws {
        let template = Template(page(), rect: CGRect(x: 60, y: 60, width: 120, height: 30))
        let found = try XCTUnwrap(template.locate(in: page(dx: 2, dy: -1), near: CGPoint(x: 60, y: 60)))
        XCTAssertEqual(found.x, 62, accuracy: 0.5)
        XCTAssertEqual(found.y, 59, accuracy: 0.5)
    }

    func testFindsFastScrolls() throws {
        let template = Template(page(), rect: CGRect(x: 60, y: 150, width: 120, height: 30))
        let found = try XCTUnwrap(template.locate(in: page(dy: -90), near: CGPoint(x: 60, y: 150)))
        XCTAssertEqual(found.x, 60, accuracy: 0.5)
        XCTAssertEqual(found.y, 60, accuracy: 0.5)
    }

    func testLosesTextThatIsGone() {
        let template = Template(page(), rect: CGRect(x: 60, y: 60, width: 120, height: 30))
        let blank = LumaPlane(time: 0, width: 400, height: 300, pixels: [UInt8](repeating: 240, count: 400 * 300))
        XCTAssertNil(template.locate(in: blank, near: CGPoint(x: 60, y: 60)))
    }
}
