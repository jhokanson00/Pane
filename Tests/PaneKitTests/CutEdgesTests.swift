import XCTest
@testable import PaneKit

final class CutEdgesTests: XCTestCase {
    /// Levels every 10 ms: quiet (-85 dB) except the given sounds, (start, end, dB).
    private func levels(_ sounds: [(Double, Double, Float)], length: Double = 12) -> AudioLevels {
        var values = [Float](repeating: -85, count: Int(length / AudioLevels.window))
        for (start, end, level) in sounds {
            for index in Int((start / AudioLevels.window).rounded())..<Int((end / AudioLevels.window).rounded()) {
                values[index] = level
            }
        }
        return AudioLevels(levels: values)
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> CaptionWord {
        CaptionWord(text: text, start: start, end: end)
    }

    /// A sentence (1–2 s), a flubbed try (3–4 s), a retake (6–7 s), with speech
    /// recognition's times a little off from the sound.
    private let take: [(Double, Double, Float)] = [(1, 2, -22), (3, 4, -22), (6, 7, -22), (8, 9, -22)]

    func testARetakeStartingBeforeItsWordKeepsItsStartAndALeadIn() {
        // The retake's sound starts at 6.0 s; its word was timed at 6.12 s.
        let words = [word("Kept.", 1, 2), word("Flub", 3, 4), word("Retake", 6.12, 7)]
        let cuts = CutEdges.placed([3...6.12], levels: levels(take), words: words, pause: .medium)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].upperBound, 6 - CutEdges.margin - 0.25, accuracy: 0.011)
    }

    func testAFlubStartingBeforeItsWordIsCutFromItsFirstSound() {
        // The flub's sound starts at 3.0 s; its word was timed at 3.04 s. The silence before
        // it (2–3 s) stays.
        let words = [word("Kept.", 1, 2), word("Flub", 3.04, 4), word("Retake", 6, 7)]
        let cuts = CutEdges.placed([3.04...6], levels: levels(take), words: words, pause: .short)
        XCTAssertEqual(cuts[0].lowerBound, 3 - CutEdges.margin, accuracy: 0.011)
    }

    func testABreathBeforeTheFlubIsCutWithIt() {
        // A soft breath (-60 dB) runs into the flub's first word.
        var sounds = take
        sounds.append((2.8, 3, -60))
        let words = [word("Kept.", 1, 2), word("Flub", 3, 4), word("Retake", 6, 7)]
        let cuts = CutEdges.placed([3...6], levels: levels(sounds), words: words, pause: .short)
        XCTAssertEqual(cuts[0].lowerBound, 2.8 - CutEdges.margin, accuracy: 0.011)
    }

    func testTheLeadInIsOnlyTheSilenceThereIs() {
        // "sorry" ends 0.15 s before the retake: no more than that is kept before it.
        var sounds = take
        sounds.append((4.5, 5.85, -22))
        let words = [word("Kept.", 1, 2), word("Flub", 3, 4), word("sorry", 4.5, 5.85), word("Retake", 6, 7)]
        let cuts = CutEdges.placed([3...6], levels: levels(sounds), words: words, pause: .long)
        XCTAssertEqual(cuts[0].upperBound, 5.85, accuracy: 0.011)
    }

    func testAMouseClickInTheSilenceIsNotSpeech() {
        var sounds = take
        sounds.append((5.7, 5.72, -20))
        let words = [word("Kept.", 1, 2), word("Flub", 3, 4), word("Retake", 6, 7)]
        let cuts = CutEdges.placed([3...6], levels: levels(sounds), words: words, pause: .medium)
        XCTAssertEqual(cuts[0].upperBound, 6 - CutEdges.margin - 0.25, accuracy: 0.011)
    }

    func testTouchingCutsMakeOneJoin() {
        let words = [word("Kept.", 1, 2), word("Flub", 3, 4), word("Again", 6, 7), word("Retake", 8, 9)]
        let cuts = CutEdges.placed([3...6, 6...8], levels: levels(take), words: words, pause: .medium)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].lowerBound, 3 - CutEdges.margin, accuracy: 0.011)
        XCTAssertEqual(cuts[0].upperBound, 8 - CutEdges.margin - 0.25, accuracy: 0.011)
    }

    func testJoinFadesRampOutAndIn() {
        let fades = JoinFades(edit: VideoEdit(cuts: [1...2]), duration: 3)
        let rate = ClickSound.sampleRate, length = Int(JoinFades.length * Double(rate))
        // Mono, from 0.5 s to 2.5 s: the fade out ends at 1 s, the fade in starts at 2 s.
        let start = rate / 2
        var samples = [Float](repeating: 1, count: 2 * rate)
        XCTAssertTrue(fades.overlaps(start: start, frames: samples.count))
        XCTAssertFalse(fades.overlaps(start: 0, frames: start))
        samples.withUnsafeMutableBufferPointer { fades.apply(to: $0, channels: 1, start: start) }
        let out = rate - start, into = 2 * rate - start
        XCTAssertEqual(samples[out - length - 1], 1)
        XCTAssertEqual(samples[out - 1], 1 / Float(length), accuracy: 1e-6)
        XCTAssertEqual(samples[out - length / 2], 0.5, accuracy: 0.01)
        XCTAssertEqual(samples[into], 1 / Float(length), accuracy: 1e-6)
        XCTAssertEqual(samples[into + length], 1)
    }
}
