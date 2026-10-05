import XCTest
@testable import PaneKit

final class PageShiftTests: XCTestCase {
    let width = 400, height = 400
    /// The text line being followed: 200 px wide, 20 px tall, mid-screen.
    let rect = CGRect(x: 100, y: 190, width: 200, height: 20)

    /// Small seeded generator so the pages are the same on every run.
    struct Seeded {
        var state: UInt64
        mutating func next(_ range: ClosedRange<Int>) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((state >> 33) % UInt64(range.count))
        }
    }

    /// A tall page of text-like lines: dark bands of varying height and darkness with
    /// light gaps between them, broken into "words" across each line. Row 0 of the page
    /// is 200 px above the top of the screen.
    func pageRows(seed: UInt64) -> [UInt8] {
        var rng = Seeded(state: seed)
        var rows: [UInt8] = []
        while rows.count < height + 400 {
            rows += Array(repeating: 245, count: rng.next(4...12))
            rows += Array(repeating: UInt8(rng.next(40...200)), count: rng.next(6...14))
        }
        return rows
    }

    /// The screen showing `rows`, scrolled so the page sits `shift` px lower than at 0.
    func frame(_ rows: [UInt8], shift: Int, time: Double = 0) -> LumaPlane {
        var pixels = [UInt8](repeating: 245, count: width * height)
        for y in 0..<height {
            let value = rows[y + 200 - shift]
            guard value != 245 else { continue }
            for x in 0..<width where (x / 9) % 5 != 4 {
                pixels[y * width + x] = value
            }
        }
        return LumaPlane(time: time, width: width, height: height, pixels: pixels)
    }

    /// Box-blurs a frame vertically over `radius` rows each way, like motion smear.
    func smeared(_ plane: LumaPlane, radius: Int) -> LumaPlane {
        var pixels = plane.pixels
        for x in 0..<plane.width {
            for y in 0..<plane.height {
                var sum = 0, count = 0
                for yy in max(0, y - radius)...min(plane.height - 1, y + radius) {
                    sum += Int(plane.pixels[yy * plane.width + x])
                    count += 1
                }
                pixels[y * plane.width + x] = UInt8(sum / count)
            }
        }
        return LumaPlane(time: plane.time, width: plane.width, height: plane.height, pixels: pixels)
    }

    func testFollowsAScrollDown() throws {
        let rows = pageRows(seed: 1)
        let shift = try XCTUnwrap(PageShift.vertical(from: frame(rows, shift: 0), to: frame(rows, shift: 37), around: rect))
        XCTAssertEqual(shift, 37, accuracy: 1)
    }

    func testFollowsAScrollUp() throws {
        let rows = pageRows(seed: 2)
        let shift = try XCTUnwrap(PageShift.vertical(from: frame(rows, shift: 0), to: frame(rows, shift: -12), around: rect))
        XCTAssertEqual(shift, -12, accuracy: 1)
    }

    func testFollowsASmearedScroll() throws {
        let rows = pageRows(seed: 3)
        let before = smeared(frame(rows, shift: 0), radius: 6)
        let down = smeared(frame(rows, shift: 37), radius: 6)
        let up = smeared(frame(rows, shift: -12), radius: 6)
        XCTAssertEqual(try XCTUnwrap(PageShift.vertical(from: before, to: down, around: rect)), 37, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(PageShift.vertical(from: before, to: up, around: rect)), -12, accuracy: 2)
    }

    func testBlankPageIsNil() {
        let blank = LumaPlane(time: 0, width: width, height: height,
                              pixels: [UInt8](repeating: 245, count: width * height))
        XCTAssertNil(PageShift.vertical(from: blank, to: blank, around: rect))
    }

    func testRepeatingRowsAreAmbiguous() {
        // List rows every 10 px: a move of 3 looks the same as 13, 23, -7...
        var rows = [UInt8]()
        while rows.count < height + 400 {
            rows += Array(repeating: 245, count: 4) + Array(repeating: 60, count: 6)
        }
        XCTAssertNil(PageShift.vertical(from: frame(rows, shift: 0), to: frame(rows, shift: 3), around: rect))
    }

    func testDifferentPageIsNil() {
        let before = frame(pageRows(seed: 4), shift: 0)
        // A new page with no lines in common: rows of random noise.
        var rng = Seeded(state: 99)
        let after = LumaPlane(time: 0, width: width, height: height,
                              pixels: (0..<(width * height)).map { _ in UInt8(rng.next(0...255)) })
        XCTAssertNil(PageShift.vertical(from: before, to: after, around: rect))
        // And a switch to an unrelated page of text.
        XCTAssertNil(PageShift.vertical(from: before, to: frame(pageRows(seed: 5), shift: 0), around: rect))
    }
}
