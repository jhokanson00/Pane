import Foundation

/// One spoken word and when it was said, in seconds into the video.
public struct CaptionWord: Equatable, Sendable {
    /// The word with any punctuation the transcriber attached, such as "Settings,".
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// Joins transcriber pieces into whole words. A transcriber times pieces of text that
    /// can be part of a word, a whole word with its leading space, or several words; a
    /// new word starts at a space. Pieces without a time (usually punctuation) join the
    /// word before them.
    public static func words(fromPieces pieces: [(text: String, start: Double?, end: Double?)]) -> [CaptionWord] {
        var words: [CaptionWord] = []
        var current: (text: String, start: Double?, end: Double?)?

        func finish() {
            if let word = current, !word.text.isEmpty, let start = word.start, let end = word.end {
                words.append(CaptionWord(text: word.text, start: start, end: max(end, start)))
            } else if let word = current, !word.text.isEmpty, !words.isEmpty {
                // Untimed text on its own: keep it with the word before.
                words[words.count - 1].text += word.text
            }
            current = nil
        }

        for piece in pieces {
            // A piece holding several words shares its time among them by length.
            let parts = piece.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let letters = Double(max(parts.reduce(0) { $0 + $1.count }, 1))
            var cursor = piece.start
            for (index, part) in parts.enumerated() {
                if index > 0 { finish() }
                guard !part.isEmpty else { continue }
                var end: Double?
                if let start = piece.start, let pieceEnd = piece.end, let from = cursor {
                    end = parts.count == 1 ? pieceEnd : from + (pieceEnd - start) * Double(part.count) / letters
                }
                if current == nil {
                    current = (part, cursor, end)
                } else {
                    current!.text += part
                    if current!.start == nil { current!.start = cursor }
                    if let end { current!.end = max(current!.end ?? end, end) }
                }
                cursor = end ?? cursor
            }
        }
        finish()
        return words
    }
}

/// One caption on screen: up to two short lines, shown from `start` to `end` seconds.
public struct Caption: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// The lines, separated by "\n".
    public var text: String

    public var lines: [String] { text.components(separatedBy: "\n") }

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Captions made from a recording's narration, split into short cues that are easy to
/// read, and written out as SRT.
public struct Captions: Codable, Equatable, Sendable {
    /// Sorted by time, never overlapping.
    public var cues: [Caption]
    /// The spoken language, as a code such as "en".
    public var language: String

    public init(cues: [Caption], language: String) {
        self.cues = cues
        self.language = language
    }

    /// How cues are cut. The defaults follow common subtitle practice: two lines of up
    /// to 42 characters, on screen for one to six seconds.
    public struct Rules: Sendable {
        public var maxLineLength = 42
        /// One or two lines.
        public var maxLines = 2
        public var minDuration = 1.0
        public var maxDuration = 6.0
        /// A pause this long always starts a new cue, so a caption isn't left on screen
        /// through silence.
        public var maxPause = 1.2
        /// Characters per second people can comfortably read. Short cues stay up long
        /// enough for this.
        public var readingSpeed = 17.0
        /// Leave out "um" and "uh". Captions for a tutorial read better without them.
        public var dropFillers = true

        public init() {}
    }

    /// Splits words into cues. Each cut is chosen for the whole transcript at once, so
    /// cues end at sentence ends where they can, then at commas, before words like "and"
    /// or "but", or at pauses, rather than wherever a line fills up.
    public init(words: [CaptionWord], language: String, rules: Rules = Rules()) {
        var words = words
            .map { CaptionWord(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: $0.start, end: $0.end) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
        if rules.dropFillers { words = Self.removingFillers(words) }
        self.init(cues: Self.cues(for: words, rules: rules), language: language)
    }

    private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm"]

    /// The words without fillers. A sentence that ended on a filler ("And then uh...")
    /// ends on the word before it instead, and a sentence that started with one
    /// ("Um, so we…") starts with a capital on the next word.
    static func removingFillers(_ words: [CaptionWord]) -> [CaptionWord] {
        var kept: [CaptionWord] = []
        var capitalizeNext = false
        for word in words {
            guard fillers.contains(bare(word.text)) else {
                var word = word
                if capitalizeNext, let first = word.text.first {
                    word.text = first.uppercased() + word.text.dropFirst()
                }
                capitalizeNext = false
                kept.append(word)
                continue
            }
            if word.text.first?.isUppercase == true { capitalizeNext = true }
            let ending = String(word.text.reversed().prefix { $0.isPunctuation }.reversed())
            if endsSentence(ending), let last = kept.indices.last, !endsSentence(kept[last].text) {
                kept[last].text = String(kept[last].text.reversed().drop { $0 == "," || $0 == ";" || $0 == ":" }.reversed())
                    + ending
            }
        }
        return kept
    }

    /// The cue on screen at `time`, if any.
    public func cue(at time: Double) -> Caption? {
        cueIndex(at: time).map { cues[$0] }
    }

    public func cueIndex(at time: Double) -> Int? {
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].end <= time { low = mid + 1 } else { high = mid }
        }
        guard low < cues.count, cues[low].start <= time else { return nil }
        return low
    }

    /// The captions for a trimmed copy that keeps `range` (seconds of the recording):
    /// moved to start at zero, cut to the range, and without the ones outside it.
    public func trimmed(to range: ClosedRange<Double>?) -> Captions {
        guard let range else { return self }
        let kept = cues.compactMap { cue -> Caption? in
            let start = max(cue.start, range.lowerBound), end = min(cue.end, range.upperBound)
            guard end - start > 0.001 else { return nil }
            return Caption(start: start - range.lowerBound, end: end - range.lowerBound, text: cue.text)
        }
        return Captions(cues: kept, language: language)
    }

    /// The captions on the timeline of a copy made with `edit`: trimmed and cut parts
    /// left out, the rest moved up. A cue across a cut runs from its first kept moment to
    /// its last. (For captions without the cut words, make them from the words left.)
    public func edited(_ edit: VideoEdit, duration: Double) -> Captions {
        let parts = edit.kept(duration: duration)
        let kept = cues.compactMap { cue -> Caption? in
            let pieces = parts.compactMap { part -> (Double, Double)? in
                let start = max(cue.start, part.lowerBound), end = min(cue.end, part.upperBound)
                guard end - start > 0.001, let from = edit.outputTime(start, duration: duration),
                      let to = edit.outputTime(end, duration: duration) else { return nil }
                return (from, to)
            }
            guard let first = pieces.first, let last = pieces.last else { return nil }
            return Caption(start: first.0, end: last.1, text: cue.text)
        }
        return Captions(cues: kept, language: language)
    }

    // MARK: - SRT

    /// The captions as an SRT file, the format video sites and players accept.
    public var srt: String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(Self.srtTime(cue.start)) --> \(Self.srtTime(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// "01:02:03,456"
    static func srtTime(_ seconds: Double) -> String {
        let total = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
    }

    // MARK: - Cutting

    private static let conjunctions: Set<String> = [
        "and", "but", "or", "so", "because", "then", "which", "that", "when", "if", "while", "where", "until",
        "unless", "although", "though", "since", "after", "before",
    ]
    /// Words that read badly at the end of a line or cue, cut off from what follows.
    private static let leaders: Set<String> = [
        "the", "a", "an", "to", "of", "in", "on", "at", "for", "with", "by", "from", "my", "your", "our", "this",
        "and", "or", "but", "is", "are", "i", "you", "we", "it", "can", "will",
    ]

    private static func bare(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func endsSentence(_ word: String) -> Bool {
        word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!") || word.hasSuffix("…")
    }

    private static func endsClause(_ word: String) -> Bool {
        word.hasSuffix(",") || word.hasSuffix(";") || word.hasSuffix(":") || word.hasSuffix("—")
    }

    /// The cheapest way to cut the transcript into cues, by dynamic programming over
    /// where each cue ends.
    private static func cues(for words: [CaptionWord], rules: Rules) -> [Caption] {
        let count = words.count
        guard count > 0 else { return [] }
        let maxCharacters = rules.maxLineLength * max(rules.maxLines, 1)
        var best = [Double](repeating: .infinity, count: count + 1)
        var from = [Int](repeating: 0, count: count + 1)
        best[0] = 0

        for end in 1...count {
            var characters = -1
            for start in stride(from: end - 1, through: 0, by: -1) {
                characters += words[start].text.count + 1
                let single = start == end - 1
                if !single {
                    if characters > maxCharacters { break }
                    if words[end - 1].end - words[start].start > rules.maxDuration { break }
                    if words[start + 1].start - words[start].end >= rules.maxPause { break }
                }
                guard best[start] < .infinity,
                      single || lines(for: words[start..<end], rules: rules) != nil else { continue }
                let cost = best[start] + self.cost(words, start..<end, characters: characters, rules: rules)
                if cost < best[end] {
                    best[end] = cost
                    from[end] = start
                }
            }
        }

        var ranges: [Range<Int>] = []
        var end = count
        while end > 0 {
            ranges.append(from[end]..<end)
            end = from[end]
        }
        ranges.reverse()

        var cues = ranges.map { range in
            Caption(start: words[range.lowerBound].start, end: words[range.upperBound - 1].end,
                    text: (lines(for: words[range], rules: rules)
                           ?? [words[range].map(\.text).joined(separator: " ")]).joined(separator: "\n"))
        }
        // Short cues stay up long enough to read, without running into the next one.
        for index in cues.indices {
            let characters = Double(cues[index].text.count)
            let wanted = cues[index].start + max(rules.minDuration, characters / rules.readingSpeed)
            var end = max(cues[index].end, min(wanted, cues[index].start + rules.maxDuration))
            if index + 1 < cues.count { end = min(end, cues[index + 1].start) }
            cues[index].end = max(end, cues[index].start)
        }
        return cues
    }

    /// What a cue costs: each cue costs a little, so they aren't cut needlessly short,
    /// plus more the worse its last word is as a place to stop.
    private static func cost(_ words: [CaptionWord], _ range: Range<Int>, characters: Int, rules: Rules) -> Double {
        let last = words[range.upperBound - 1]
        var cost = 1.0

        if range.upperBound < words.count {
            let next = words[range.upperBound]
            var stop: Double
            if endsSentence(last.text) {
                stop = 0
            } else if endsClause(last.text) {
                stop = 1.5
            } else if conjunctions.contains(bare(next.text)) {
                stop = 3
            } else {
                stop = 6
            }
            if leaders.contains(bare(last.text)) && !endsSentence(last.text) && !endsClause(last.text) { stop += 3 }
            // A pause in the speech is a natural place to stop.
            let pause = next.start - last.end
            if pause >= rules.maxPause { stop = 0 } else if pause >= 0.5 { stop = min(stop, 1) }
            cost += stop
        }

        let duration = last.end - words[range.lowerBound].start
        if duration < rules.minDuration { cost += 3 * (rules.minDuration - duration) / rules.minDuration }
        if characters < 12 { cost += 1.5 }
        if duration > rules.maxDuration - 1 { cost += duration - (rules.maxDuration - 1) }
        return cost
    }

    /// The words laid out in at most `maxLines` lines of `maxLineLength`, or nil if they
    /// don't fit. Two lines are split near the middle, preferring a comma or a word like
    /// "and" for the break, and never leaving "the" or "to" hanging at a line's end.
    static func lines(for words: ArraySlice<CaptionWord>, rules: Rules) -> [String]? {
        let texts = words.map(\.text)
        let whole = texts.joined(separator: " ")
        if whole.count <= rules.maxLineLength { return [whole] }
        guard rules.maxLines >= 2, texts.count >= 2 else { return nil }

        var best: (split: Int, cost: Double)?
        var first = -1
        for split in 1..<texts.count {
            first += texts[split - 1].count + 1
            let second = whole.count - first - 1
            guard first <= rules.maxLineLength, second <= rules.maxLineLength else { continue }
            var cost = Double(abs(first - second))
            let before = texts[split - 1]
            if endsSentence(before) || endsClause(before) {
                cost -= 12
            } else if conjunctions.contains(bare(texts[split])) {
                cost -= 6
            } else if leaders.contains(bare(before)) {
                cost += 8
            }
            if best == nil || cost < best!.cost { best = (split, cost) }
        }
        guard let split = best?.split else { return nil }
        return [texts[..<split].joined(separator: " "), texts[split...].joined(separator: " ")]
    }
}
