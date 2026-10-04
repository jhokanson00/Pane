import XCTest
@testable import PaneKit

final class RetakeFinderTests: XCTestCase {
    let script = PrompterScript("""
    This is Pane, a free screen recorder for Mac.
    Everything here is private: names, emails, phone numbers.
    Every click gets a ring and a sound, and Pane zooms in so it's easy to see.
    And anything on my own word list, like a client's name.
    """)

    /// Words 0.4 s apart, as captions would time them.
    private func narration(_ text: String) -> [CaptionWord] {
        text.split(separator: " ").enumerated().map { index, word in
            CaptionWord(text: String(word), start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.3)
        }
    }

    private func find(_ text: String) -> (retakes: [Retake], words: [CaptionWord]) {
        let words = narration(text)
        return (RetakeFinder.find(script: script, words: words), words)
    }

    func testNoRetakesInAPlainReading() {
        let (retakes, _) = find("""
        this is pane a free screen recorder for mac everything here is private names emails phone numbers \
        every click gets a ring and a sound and pane zooms in so it's easy to see
        """)
        XCTAssertEqual(retakes, [])
    }

    func testRestartingASentenceAndGettingAsFarAsBefore() {
        // The live prompter doesn't move here: the retake ends where the first try did.
        let (retakes, words) = find("""
        this is pane a free screen recorder for mac every click gets a ring \
        every click gets a ring and a sound and pane zooms in
        """)
        XCTAssertEqual(retakes.count, 1)
        let firstTry = words.firstIndex { $0.text == "every" }!
        let retake = words.lastIndex { $0.text == "every" }!
        XCTAssertEqual(retakes.first?.cut, words[firstTry].start...words[retake].start)
        XCTAssertEqual(retakes.first?.text.hasPrefix("Every click gets a ring"), true)
    }

    func testRedoWithAnAdLibInBetweenCutsTheAdLibToo() {
        let (retakes, words) = find("""
        this is pane a free screen recorder for mac everything here is private names emails oh no sorry \
        everything here is private names emails phone numbers every click gets a ring
        """)
        XCTAssertEqual(retakes.count, 1)
        let firstTry = words.firstIndex { $0.text == "everything" }!
        let retake = words.lastIndex { $0.text == "everything" }!
        XCTAssertEqual(retakes.first?.cut, words[firstTry].start...words[retake].start)
    }

    func testAdLibbingAloneIsNotARetake() {
        let (retakes, _) = find("""
        this is pane a free screen recorder for mac hold on let me move this window out of the way \
        everything here is private names emails phone numbers
        """)
        XCTAssertEqual(retakes, [])
    }

    func testTwoRetakesOfOneSentenceCutBothEarlierTries() {
        let (retakes, words) = find("""
        everything here is private names uh everything here is private um \
        everything here is private names emails phone numbers
        """)
        XCTAssertEqual(retakes.count, 2)
        let starts = words.indices.filter { words[$0].text == "everything" }.map { words[$0].start }
        XCTAssertEqual(retakes.map(\.cut), [starts[0]...starts[1], starts[1]...starts[2]])
        // Together they leave only the last try.
        let edit = VideoEdit(cuts: retakes.map(\.cut))
        XCTAssertEqual(edit.kept(duration: words.last!.end), [starts[2]...words.last!.end])
    }
}
