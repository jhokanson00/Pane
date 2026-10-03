import CoreImage
import XCTest
@testable import PaneKit

final class CaptionsTests: XCTestCase {
    /// Words spoken one after another, `pace` seconds each, with no pauses.
    private func speak(_ text: String, from start: Double = 0, pace: Double = 0.3) -> [CaptionWord] {
        text.split(separator: " ").enumerated().map { index, word in
            CaptionWord(text: String(word), start: start + Double(index) * pace, end: start + Double(index + 1) * pace)
        }
    }

    private func assertReadable(_ captions: Captions, file: StaticString = #filePath, line: UInt = #line) {
        for (index, cue) in captions.cues.enumerated() {
            XCTAssertLessThanOrEqual(cue.lines.count, 2, cue.text, file: file, line: line)
            for text in cue.lines { XCTAssertLessThanOrEqual(text.count, 42, text, file: file, line: line) }
            XCTAssertLessThanOrEqual(cue.end - cue.start, 6.0001, cue.text, file: file, line: line)
            XCTAssertGreaterThan(cue.end, cue.start, file: file, line: line)
            if index > 0 { XCTAssertGreaterThanOrEqual(cue.start, captions.cues[index - 1].end, file: file, line: line) }
        }
    }

    func testJoinsPiecesIntoWords() {
        let words = CaptionWord.words(fromPieces: [
            ("Hello", 0, 0.4), (" wor", 0.5, 0.7), ("ld", 0.7, 0.9), (",", nil, nil), (" two words", 1, 2), (" ", nil, nil),
            ("Next", 2.5, 2.9),
        ])
        XCTAssertEqual(words.map(\.text), ["Hello", "world,", "two", "words", "Next"])
        XCTAssertEqual(words[1].start, 0.5)
        XCTAssertEqual(words[1].end, 0.9, accuracy: 1e-9)
        // Several words in one piece share its time by length.
        XCTAssertEqual(words[2].end, 1.375, accuracy: 1e-9)
        XCTAssertEqual(words[3].start, 1.375, accuracy: 1e-9)
        XCTAssertEqual(words[3].end, 2, accuracy: 1e-9)
    }

    func testCutsAtSentencesAndClauses() {
        let words = speak("Open the Settings app and choose General. Then scroll all the way down to the bottom of the list, "
                          + "and click About to see the details of your Mac, including its serial number.")
        let captions = Captions(words: words, language: "en")
        assertReadable(captions)
        XCTAssertEqual(captions.cues.map(\.text), [
            "Open the Settings app and choose General.",
            "Then scroll all the way down\nto the bottom of the list,",
            "and click About to see the details\nof your Mac, including its serial number.",
        ])
        // Each cue runs from its first word to its last.
        XCTAssertEqual(captions.cues[0].start, 0)
        XCTAssertEqual(captions.cues[0].end, 7 * 0.3, accuracy: 1e-9)
        XCTAssertEqual(captions.cues[1].start, 7 * 0.3, accuracy: 1e-9)
    }

    func testLongSentenceWithoutPunctuationStaysWithinLimits() {
        let words = speak((1...60).map { _ in "word" }.joined(separator: " "), pace: 0.25)
        let captions = Captions(words: words, language: "en")
        assertReadable(captions)
        XCTAssertEqual(captions.cues.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }.count, 60)
    }

    func testPauseStartsNewCueAndShortCuesStayUpToRead() {
        let words = speak("Okay.", from: 1, pace: 0.2) + speak("Now open the menu.", from: 3)
        let captions = Captions(words: words, language: "en")
        XCTAssertEqual(captions.cues.map(\.text), ["Okay.", "Now open the menu."])
        // "Okay." is said in 0.2 s but stays up for a second.
        XCTAssertEqual(captions.cues[0].start, 1)
        XCTAssertEqual(captions.cues[0].end, 2, accuracy: 1e-9)

        // A long caption said quickly stays up longer, but never into the next one.
        let quick = speak("Choose a folder, then drag the files right into it now.", from: 1, pace: 0.15)
        let close = Captions(words: quick + speak("Done.", from: 4), language: "en")
        XCTAssertEqual(close.cues.count, 2)
        XCTAssertEqual(close.cues[0].end, 4, accuracy: 1e-9)
        let alone = Captions(words: quick, language: "en")
        XCTAssertEqual(alone.cues[0].end, 1 + 55 / 17.0, accuracy: 1e-9)
    }

    func testFillersAreLeftOut() {
        let words = speak("Um, so we open it, uh, here and then uh... Right.")
        XCTAssertEqual(Captions.removingFillers(words).map(\.text),
                       ["So", "we", "open", "it,", "here", "and", "then...", "Right."])
        var rules = Captions.Rules()
        rules.dropFillers = false
        XCTAssertTrue(Captions(words: words, language: "en", rules: rules).srt.contains("Um,"))
    }

    func testTwoLinesSplitNearTheMiddle() {
        let words = speak("I am going to show you how to make a new folder for the project files")
        let lines = Captions.lines(for: words[...], rules: .init())
        XCTAssertEqual(lines, ["I am going to show you how to make", "a new folder for the project files"])
        XCTAssertNil(Captions.lines(for: speak(String(repeating: "abcdefghij ", count: 9))[...], rules: .init()))
    }

    func testSRT() {
        let captions = Captions(cues: [
            Caption(start: 0.6, end: 2.8204, text: "Okay, we're trying this once again."),
            Caption(start: 3725.5, end: 3727, text: "Two lines\nof text"),
        ], language: "en")
        XCTAssertEqual(captions.srt, """
            1
            00:00:00,600 --> 00:00:02,820
            Okay, we're trying this once again.

            2
            01:02:05,500 --> 01:02:07,000
            Two lines
            of text

            """)
        XCTAssertEqual(captions.cue(at: 1)?.text, "Okay, we're trying this once again.")
        XCTAssertNil(captions.cue(at: 2.9))
        XCTAssertEqual(captions.cueIndex(at: 3726), 1)
        XCTAssertNil(captions.cue(at: 3727))
    }

    func testTrimmedCaptionsMatchTheTrimmedVideo() {
        let captions = Captions(cues: [
            Caption(start: 0.6, end: 2.8, text: "Cut off."),
            Caption(start: 2.8, end: 5.5, text: "Starts before the trim."),
            Caption(start: 6, end: 8, text: "Inside."),
            Caption(start: 9, end: 12, text: "Ends after it."),
            Caption(start: 12, end: 13, text: "Also cut off."),
        ], language: "en")
        let trimmed = captions.trimmed(to: 3...10)
        XCTAssertEqual(trimmed.cues.map(\.text), ["Starts before the trim.", "Inside.", "Ends after it."])
        XCTAssertEqual(trimmed.cues.map(\.start), [0, 3, 6])
        XCTAssertEqual(trimmed.cues.map(\.end), [2.5, 5, 7])
        XCTAssertEqual(captions.trimmed(to: nil), captions)
    }

    // MARK: - Burned in

    func testBurnedInCaptionIsDarkBoxWithWhiteTextAtBottomCenter() throws {
        let captions = Captions(cues: [Caption(start: 1, end: 3, text: "Click the blue button")], language: "en")
        let size = CGSize(width: 1280, height: 720)
        let renderer = try XCTUnwrap(CaptionRenderer(captions: captions, videoSize: size, cameraCircle: nil))
        XCTAssertFalse(renderer.isActive(at: 0.5))
        XCTAssertTrue(renderer.isActive(at: 2))

        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: size))
        let output = renderer.apply(to: gray, at: 2)
        let pixels = render(output, size: size)
        func brightness(_ x: Int, _ yFromTop: Int) -> Int { Int(pixels[(yFromTop * Int(size.width) + x) * 4]) }

        // Untouched above the caption; darkened around the text, near the bottom middle.
        XCTAssertEqual(brightness(640, 300), brightness(10, 10))
        let row = Int(size.height) - Int(size.height * 0.06) - 4
        XCTAssertLessThan(brightness(640 - 120, row), 60)
        // Somewhere in the box, the text is near white.
        let box = (Int(size.height) - 120)..<Int(size.height)
        let brightest = box.flatMap { y in stride(from: 400, to: 880, by: 1).map { brightness($0, y) } }.max() ?? 0
        XCTAssertGreaterThan(brightest, 240)
    }

    func testCaptionMovesClearOfTheCamera() throws {
        let captions = Captions(cues: [Caption(start: 0, end: 1, text: "x")], language: "en")
        let size = CGSize(width: 1920, height: 1080)
        let box = CGSize(width: 800, height: 110)

        // A small circle in the corner is already clear of a centered caption.
        let corner = try XCTUnwrap(CaptionRenderer(captions: captions, videoSize: size,
                                                   cameraCircle: CGRect(x: 0.85, y: 0.03, width: 0.12, height: 0.21)))
        XCTAssertEqual(corner.place(box), CGPoint(x: 560, y: 65))

        // A bigger one reaching toward the middle: the caption slides left of it.
        let big = try XCTUnwrap(CaptionRenderer(captions: captions, videoSize: size,
                                                cameraCircle: CGRect(x: 0.62, y: 0.03, width: 0.25, height: 0.44)))
        let slid = big.place(box)
        XCTAssertEqual(slid.y, 65)
        XCTAssertLessThanOrEqual(slid.x + box.width, 0.62 * 1920 - 21)

        // A narrow video has no room beside it, so the caption goes above it.
        let narrow = CGSize(width: 1000, height: 1080)
        let tall = try XCTUnwrap(CaptionRenderer(captions: captions, videoSize: narrow,
                                                 cameraCircle: CGRect(x: 0.6, y: 0.03, width: 0.35, height: 0.33)))
        let lifted = tall.place(box)
        XCTAssertGreaterThanOrEqual(lifted.y, (0.03 + 0.33) * 1080)
        XCTAssertEqual(lifted.x, 100)
    }

    private func render(_ image: CIImage, size: CGSize) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        CIContext().render(image, toBitmap: &pixels, rowBytes: Int(size.width) * 4,
                           bounds: CGRect(origin: .zero, size: size), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return pixels
    }
}
