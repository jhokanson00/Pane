import Foundation

/// A sentence (or part of one) said again: the first try, and anything said between it and
/// the retake ("sorry, let me redo that"), can be cut.
public struct Retake: Equatable, Sendable {
    /// From the start of the first try to the start of the retake, in seconds of the
    /// recording.
    public var cut: ClosedRange<Double>
    /// The script words that were said again.
    public var words: Range<Int>
    /// The start of those words, for showing in a list.
    public var text: String
}

/// Finds retakes in a recording made with the teleprompter, from its narration's words
/// (timed, as captions make them) and the script.
///
/// The narration is followed through the script as the teleprompter followed it live.
/// Where the latest words line up better with script words already said than with
/// anything ahead, the speaker went back: by voice, or after the "start over" key. The
/// cut runs from when those words were first said to when they were said again.
public enum RetakeFinder {
    public static func find(script: PrompterScript, words: [CaptionWord],
                            tuning: ScriptFollower.Tuning = ScriptFollower.Tuning()) -> [Retake] {
        var follower = ScriptFollower(script: script, tuning: tuning)
        // For each script word, the narration word where it was said (the latest try).
        var said: [Int: Int] = [:]
        var heard: [String] = []
        var retakes: [Retake] = []
        var lastRetake = -10

        for (index, word) in words.enumerated() {
            heard.append(word.text)
            let before = follower.position

            if index - lastRetake > 2, let again = repeatedWords(follower: follower, heard: heard, words: words,
                                                                   upTo: index, before: before) {
                let (start, first, end) = again
                if let firstTry = said[first], firstTry < start {
                    let cut = words[firstTry].start...words[start].start
                    if cut.upperBound - cut.lowerBound > 0.3 {
                        let shown = script.words[first..<min(max(before, end), first + 8)].map(\.text)
                        retakes.append(Retake(cut: cut, words: first..<max(before, end),
                                              text: shown.joined(separator: " ")))
                    }
                }
                // The retake is now the try that counts.
                for scriptWord in first..<end { said[scriptWord] = start + (scriptWord - first) }
                for scriptWord in end..<max(end, before) { said[scriptWord] = nil }
                follower.hear(Array(heard.dropLast()))
                follower.jump(to: end)
                lastRetake = index
                continue
            }

            follower.hear(heard)
            let after = follower.position
            if after > before {
                for scriptWord in before..<after where said[scriptWord] == nil {
                    said[scriptWord] = max(0, index - (after - 1 - scriptWord))
                }
            }
        }
        return retakes
    }

    /// When the latest words repeat script words already said (and match them better than
    /// anything ahead): the narration index where the repeat starts, and the script words
    /// it covers.
    private static func repeatedWords(follower: ScriptFollower, heard: [String], words: [CaptionWord],
                                      upTo index: Int, before: Int) -> (start: Int, first: Int, end: Int)? {
        let matches = follower.matches(for: heard)
        guard let behind = matches.filter({ $0.position <= before }).max(by: { $0.score < $1.score }) else { return nil }
        let ahead = matches.filter { $0.position > before }.map(\.score).max() ?? 0
        guard behind.score >= follower.tuning.midStep, behind.score > ahead + 0.5 else { return nil }

        // Walk back over the words that match one for one, to where the retake began.
        let script = follower.script
        var narration = index, scriptWord = behind.position - 1
        while narration >= 0, scriptWord >= 0,
              follower.isSimilar(words[narration].text, script.words[scriptWord].key) {
            narration -= 1
            scriptWord -= 1
        }
        let start = narration + 1, first = scriptWord + 1
        guard behind.position - first >= 2 else { return nil }
        return (start, first, behind.position)
    }
}
