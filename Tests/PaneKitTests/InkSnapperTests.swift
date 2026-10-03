import CoreVideo
import XCTest
@testable import PaneKit

final class InkSnapperTests: XCTestCase {
    /// A 4:2:0 frame of dark gray with faint "text": a block of ink from rows 40–54 and
    /// columns 20–120 (top-left origin), like gray email text on a dark sidebar.
    private func frame(width: Int = 200, height: Int = 100) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        for y in 0..<height {
            for x in 0..<width {
                // Thin strokes, mostly background in between as in real text, 40 levels
                // off the background.
                let isInk = (40..<55).contains(y) && (20..<120).contains(x) && x % 3 == 0
                luma[y * bytesPerRow + x] = isInk ? 80 : 40
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    func testGrowsToCoverTallLettersVisionLeftOut() {
        // Vision's box covers only rows 46–54 (the lowercase letters).
        let visionBox = CGRect(x: 20.0 / 200, y: 1 - 55.0 / 100, width: 100.0 / 200, height: 9.0 / 100)
        let snapped = InkSnapper.with(frame()) { $0!.snap(visionBox) }
        XCTAssertEqual(snapped.maxY, 1 - 40.0 / 100, accuracy: 0.001, "should reach the top of the ink")
        XCTAssertEqual(snapped.minY, 1 - 55.0 / 100, accuracy: 0.001)
    }

    func testCombinesTheSameTextReadInOverlappingAreas() {
        let whole = TextBox(text: "jacob@coachtide.com", rect: CGRect(x: 0.40, y: 0.5, width: 0.10, height: 0.02), kind: .email)
        let quarter = TextBox(text: "jacob@coachtide.co", rect: CGRect(x: 0.401, y: 0.499, width: 0.098, height: 0.022), kind: .email)
        let other = TextBox(text: "x@y.com", rect: CGRect(x: 0.40, y: 0.3, width: 0.05, height: 0.02), kind: .email)
        let result = RecordingScanner.combined([whole, quarter, other])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "jacob@coachtide.com")
        XCTAssertEqual(result[0].rect, whole.rect.union(quarter.rect))
    }
}
