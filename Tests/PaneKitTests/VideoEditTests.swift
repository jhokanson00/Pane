import XCTest
@testable import PaneKit

final class VideoEditTests: XCTestCase {
    func testWholeVideo() {
        let edit = VideoEdit()
        XCTAssertEqual(edit.kept(duration: 10), [0...10])
        XCTAssertTrue(edit.keepsAll(duration: 10))
        XCTAssertEqual(edit.outputTime(4, duration: 10), 4)
    }

    func testTrimAndCuts() {
        // Keep 1–9, minus 3–4 and 6–7 (given out of order, one overlapping the other).
        let edit = VideoEdit(trim: 1...9, cuts: [6...7, 3...4, 3.5...3.8])
        XCTAssertEqual(edit.kept(duration: 10), [1...3, 4...6, 7...9])
        XCTAssertEqual(edit.outputDuration(duration: 10), 6, accuracy: 1e-9)
        XCTAssertEqual(edit.span(duration: 10), 1...9)
        XCTAssertFalse(edit.keepsAll(duration: 10))

        XCTAssertEqual(edit.outputTime(2, duration: 10), 1)
        XCTAssertNil(edit.outputTime(3.5, duration: 10), "inside a cut")
        XCTAssertEqual(edit.outputTime(5, duration: 10)!, 3, accuracy: 1e-9)
        XCTAssertEqual(edit.outputTime(8, duration: 10)!, 5, accuracy: 1e-9)
        XCTAssertNil(edit.outputTime(9.5, duration: 10), "trimmed off")

        XCTAssertEqual(edit.sourceTime(3, duration: 10), 5, accuracy: 1e-9)
        XCTAssertEqual(edit.sourceTime(5, duration: 10), 8, accuracy: 1e-9)
    }

    func testCutsAtTheEdgesAndTinyOnes() {
        let edit = VideoEdit(cuts: [0...2, 9...12, 5...5.001])
        XCTAssertEqual(edit.kept(duration: 10), [2...9], "edge cuts trim; a cut under a frame is ignored")
    }

    func testGapsRetimeLikePauses() {
        let edit = VideoEdit(trim: 1...9, cuts: [3...4, 6...7])
        let gaps = edit.gaps(duration: 10)
        XCTAssertTrue(gaps.isPaused(at: 3.5))
        XCTAssertFalse(gaps.isPaused(at: 5))
        // Gaps close: 8 s is 2 s of gaps later than it would be.
        XCTAssertEqual(gaps.recordedTime(at: 8), 6, accuracy: 1e-9)
    }
}
