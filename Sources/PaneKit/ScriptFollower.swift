import Foundation

/// Keeps a teleprompter's place in a script from what speech recognition hears, so it moves
/// as the speaker talks instead of scrolling on a timer.
///
/// Each update, the last few words heard are lined up against the script near the current
/// place (a local alignment, like DNA matching). Skipped script words and words that aren't
/// in the script cost a little; misheard words that are close still count. The further a
/// match would move the place, the more words have to agree, so a stray "the" never jumps
/// ahead, and ad-libbing leaves the place where it is. Going back takes a strong match: the
/// speaker rereading a line.
public struct ScriptFollower: Sendable {
    public struct Tuning: Sendable {
        /// How many of the latest words heard are lined up.
        public var heardWords = 6
        /// How far back and ahead of the place to look, in script words.
        public var lookBack = 20
        public var lookAhead = 40

        public var exact = 2.0
        /// A short common word ("the", "and"): matches everywhere, so it counts for less.
        public var common = 1.0
        /// A near miss ("Duarte" heard as "Duarty"), or a word still being said.
        public var close = 1.2
        public var mismatch = -1.5
        /// A heard word that isn't in the script.
        public var extraWord = -1.0
        /// A script word the speaker left out.
        public var skippedWord = -0.8

        /// Least score to move forward by up to 2 words, up to 8, and further.
        public var nearStep = 1.9
        public var midStep = 3.5
        public var farStep = 5.5
        /// Least score to move back.
        public var backStep = 6.0
        /// Prefers the nearer of two equally good matches.
        public var distanceCost = 0.03

        public init() {}
    }

    public let script: PrompterScript
    public var tuning: Tuning
    /// The index of the next word to be said; `script.words.count` once it's all been said.
    public private(set) var position = 0
    /// Words heard before the last manual jump, which no longer count.
    private var heardBeforeJump = 0
    private var lastHeardCount = 0

    public init(script: PrompterScript, tuning: Tuning = Tuning()) {
        self.script = script
        self.tuning = tuning
    }

    public var isFinished: Bool { position >= script.words.count }

    /// The line being read: the one holding the next word.
    public var currentLine: Int {
        position < script.words.count ? script.words[position].line : max(0, script.lines.count - 1)
    }

    /// Cues the speaker has reached: every word before them has been said.
    public var reachedCues: Int {
        script.cues.prefix { $0.beforeWord <= position }.count
    }

    /// Moves the place by hand, for the back and forward keys. What was heard before no
    /// longer counts, or the words just said would pull the place straight back.
    public mutating func jump(to word: Int) {
        position = min(max(0, word), script.words.count)
        heardBeforeJump = lastHeardCount
    }

    /// Back to the start of the sentence being read, or to the sentence before when
    /// already at its start.
    public mutating func sentenceBack() {
        let starts = script.sentenceStarts
        guard let current = starts.lastIndex(where: { $0 < position }) else { return jump(to: 0) }
        jump(to: starts[current])
    }

    /// On to the start of the next sentence.
    public mutating func sentenceForward() {
        jump(to: script.sentenceStarts.first { $0 > position } ?? script.words.count)
    }

    /// Updates the place from everything heard so far, finished words and the recognizer's
    /// current guess together. Returns whether it moved.
    @discardableResult
    public mutating func hear(_ heard: [String]) -> Bool {
        lastHeardCount = heard.count
        let fresh = heard.dropFirst(min(heardBeforeJump, heard.count))
        let tail = fresh.lazy.map(PrompterScript.key).filter { !$0.isEmpty }.suffix(tuning.heardWords)
        guard let moved = bestPosition(for: Array(tail)), moved != position else { return false }
        position = moved
        return true
    }

    /// A place the latest words line up with: the index after the last script word they
    /// match, and how well they match.
    public struct Match: Equatable, Sendable {
        public let position: Int
        public let score: Double
    }

    /// Every place near the current one that the latest heard words could end at, behind
    /// or ahead (`RetakeFinder` uses the ones behind: words said again).
    public func matches(for heard: [String]) -> [Match] {
        let tail = Array(heard.dropFirst(min(heardBeforeJump, heard.count)).lazy
            .map(PrompterScript.key).filter { !$0.isEmpty }.suffix(tuning.heardWords))
        return candidates(for: tail)
    }

    private func bestPosition(for heard: [String]) -> Int? {
        var best: (position: Int, rank: Double)?
        for match in candidates(for: heard) {
            let step = match.position - position
            guard step != 0, match.score >= required(step: step) else { continue }
            let rank = match.score - tuning.distanceCost * Double(abs(step))
            if best == nil || rank > best!.rank { best = (match.position, rank) }
        }
        return best?.position
    }

    private func candidates(for heard: [String]) -> [Match] {
        let words = script.words
        guard !heard.isEmpty, !words.isEmpty else { return [] }
        let lower = max(0, position - tuning.lookBack)
        let upper = min(words.count, position + tuning.lookAhead)
        guard lower < upper else { return [] }
        let window = words[lower..<upper].map(\.key)
        let rows = heard.count, columns = window.count

        // score[i][j]: best alignment ending with heard word i-1 against script word j-1.
        var score = Array(repeating: Array(repeating: 0.0, count: columns + 1), count: rows + 1)
        for i in 1...rows {
            for j in 1...columns {
                let diagonal = score[i - 1][j - 1] + similarity(heard[i - 1], window[j - 1])
                let extra = score[i - 1][j] + tuning.extraWord
                let skipped = score[i][j - 1] + tuning.skippedWord
                score[i][j] = max(0, diagonal, extra, skipped)
            }
        }

        // The match has to reach the newest word (or the one before it, which allows a last
        // word that's still half said), and end on a script word that matched it.
        var best: [Int: Double] = [:]
        for (row, allowance) in [(rows, 0.0), (rows - 1, -0.5)] where row >= 1 {
            for j in 1...columns where similarity(heard[row - 1], window[j - 1]) > 0 {
                let total = score[row][j] + allowance
                if total > (best[lower + j] ?? 0) { best[lower + j] = total }
            }
        }
        return best.map { Match(position: $0.key, score: $0.value) }.sorted { $0.position < $1.position }
    }

    /// Whether a heard word counts as the written one (the same, close, or half said).
    func isSimilar(_ heard: String, _ written: String) -> Bool {
        similarity(PrompterScript.key(heard), written) > 0
    }

    private func required(step: Int) -> Double {
        switch step {
        case ..<0: tuning.backStep
        case 1...2: tuning.nearStep
        case 3...8: tuning.midStep
        default: tuning.farStep
        }
    }

    private func similarity(_ heard: String, _ written: String) -> Double {
        if heard == written { return Self.commonWords.contains(written) ? tuning.common : tuning.exact }
        // A word the recognizer is still hearing: "num" for "numbers".
        if heard.count >= 3, written.hasPrefix(heard) { return tuning.close }
        let longest = max(heard.count, written.count)
        if longest >= 4, Double(Self.editDistance(heard, written)) <= Double(longest) * 0.3 { return tuning.close }
        return tuning.mismatch
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    private static let commonWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "for", "with", "is",
        "it", "its", "this", "that", "i", "you", "we", "my", "your", "so", "be", "are", "can",
        "as", "by", "if", "then", "here", "there", "now", "just", "do", "me", "up", "1",
    ]
}
