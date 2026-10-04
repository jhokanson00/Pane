import AVFoundation
import PaneKit

/// `pane-tool follow`: plays a recording's narration into live speech recognition at real
/// speed, follows a teleprompter script with it, and measures how far behind the speaker
/// the prompter's place stays.
///
/// When each script word was really said comes from the finished transcript (as captions
/// make it), lined up with the script. A word's lag is how long after it was said the
/// prompter moved past it.
enum FollowTool {
    static func run(_ args: [String]) async throws {
        let usage = "usage: pane-tool follow <audio or video> <script.txt> [--fast] [--quiet]"
        let fast = args.contains("--fast"), quiet = args.contains("--quiet")
        let rest = args.filter { !$0.hasPrefix("--") }
        guard rest.count == 3 else { fail(usage) }
        guard #available(macOS 26, *) else { fail("Live speech recognition needs macOS 26 or later") }
        let url = URL(fileURLWithPath: rest[1])
        let script = PrompterScript(try String(contentsOfFile: rest[2], encoding: .utf8))
        guard !script.words.isEmpty else { fail("The script has no words to say") }

        // When each script word was said, from the finished transcript.
        let spoken = try await CaptionTranscriber.words(url: url)
        let said = align(script: script.words.map(\.key), heard: spoken.map { PrompterScript.key($0.text) })
            .map { $0.map { spoken[$0].end } }
        print("Script: \(script.words.count) words, \(script.cues.count) cues. Heard \(spoken.count) words; "
              + "\(said.compactMap { $0 }.count) line up with the script.")

        // Live: feed the audio in real time and follow.
        let buffers = try readAudio(url)
        let log = FollowLog(script: script)
        let transcriber = try await LiveTranscriber.start(vocabulary: script.vocabulary) { heard in
            log.hear(heard)
        }
        let clock = ContinuousClock(), start = clock.now
        log.start = start
        var fed = 0.0
        for buffer in buffers {
            if !fast {
                let due = start.advanced(by: .seconds(fed))
                if due > clock.now { try await Task.sleep(until: due, clock: clock) }
            }
            transcriber.append(buffer)
            fed += Double(buffer.frameLength) / buffer.format.sampleRate
        }
        await transcriber.finish()

        report(script: script, said: said, log: log, quiet: quiet, fast: fast)
    }

    // MARK: - Report

    private static func report(script: PrompterScript, said: [Double?], log: FollowLog, quiet: Bool, fast: Bool) {
        let reached = log.reached   // when the place first moved past each word
        var lags: [Double] = []
        var missed = 0
        for (index, time) in said.enumerated() {
            guard let time else { continue }
            if let at = reached[index] { lags.append(at - time) } else { missed += 1 }
        }

        if !quiet {
            print("\nline  said    reached  lag    words")
            for (number, line) in script.lines.enumerated() where !line.words.isEmpty {
                let last = line.words.upperBound - 1
                let saidAt = said[last].map { String(format: "%6.2f", $0) } ?? "     -"
                let reachedAt = reached[last].map { String(format: "%6.2f", $0) } ?? "     -"
                var lag = "    -"
                if let saidTime = said[last], let reachedTime = reached[last] {
                    lag = String(format: "%+5.2f", reachedTime - saidTime)
                }
                let text = script.words[line.words].map(\.text).joined(separator: " ")
                print(String(format: "%4d  %@  %@   %@  %@", number + 1, saidAt, reachedAt, lag,
                             String(text.prefix(60))))
            }
        }

        let slowest = said.indices.compactMap { index -> (Int, Double)? in
            guard let time = said[index], let at = reached[index] else { return nil }
            return (index, at - time)
        }.sorted { $0.1 > $1.1 }.prefix(5)
        print("\nSlowest words: " + slowest.map { index, lag in
            String(format: "%@ (word %d, said %.2f s) %+.2f s", script.words[index].text, index, said[index]!, lag)
        }.joined(separator: "; "))
        lags.sort()
        func percentile(_ p: Double) -> Double { lags.isEmpty ? .nan : lags[min(lags.count - 1, Int(Double(lags.count) * p))] }
        print(String(format: "\nLag behind the speaker%@: median %.2f s, 90%% %.2f s, worst %.2f s; %d of %d said words never passed.",
                     fast ? " (--fast: not real time, lags meaningless)" : "",
                     percentile(0.5), percentile(0.9), lags.last ?? .nan, missed, lags.count + missed))
        // Running ahead of the speaker is worse than lagging: the speaker loses their place.
        var worstLead = 0, leadTime = 0.0
        for (time, position) in log.positions {
            let truth = said.prefix { ($0 ?? -1) <= time }.count
            if position - truth > worstLead { worstLead = position - truth; leadTime = time }
        }
        print(worstLead > 0
              ? String(format: "Furthest ahead of the speaker: %d words, at %.2f s.", worstLead, leadTime)
              : "Never ahead of the speaker.")
        print("Updates from the recognizer: \(log.updates); place moved \(log.moves) times.")
    }

    // MARK: - Truth

    /// Lines up script words with heard words (Needleman–Wunsch), returning for each script
    /// word the heard word it matches, if any.
    static func align(script: [String], heard: [String]) -> [Int?] {
        let n = script.count, m = heard.count
        guard n > 0, m > 0 else { return Array(repeating: nil, count: n) }
        func similar(_ a: String, _ b: String) -> Bool {
            a == b || (max(a.count, b.count) >= 4 && Double(editDistance(a, b)) <= Double(max(a.count, b.count)) * 0.3)
        }
        let gap = -1.0
        var score = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in 0...n { score[i][0] = Double(i) * gap }
        for j in 0...m { score[0][j] = Double(j) * gap }
        for i in 1...n {
            for j in 1...m {
                score[i][j] = max(score[i - 1][j - 1] + (similar(script[i - 1], heard[j - 1]) ? 2 : -1),
                                  score[i - 1][j] + gap, score[i][j - 1] + gap)
            }
        }
        var result = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0, j > 0 {
            let match = similar(script[i - 1], heard[j - 1])
            if score[i][j] == score[i - 1][j - 1] + (match ? 2 : -1) {
                if match { result[i - 1] = j - 1 }
                i -= 1; j -= 1
            } else if score[i][j] == score[i - 1][j] + gap {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - Audio

    /// The first sound track as mono float buffers of 0.1 s.
    private static func readAudio(_ url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else { fail("Unsupported audio") }
        let chunk = AVAudioFrameCount(rate / 10)
        var buffers: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                  let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunk) else { break }
            try file.read(into: source, frameCount: chunk)
            guard source.frameLength > 0 else { break }
            buffer.frameLength = source.frameLength
            // The first channel: the microphone.
            memcpy(buffer.floatChannelData![0], source.floatChannelData![0], Int(source.frameLength) * 4)
            buffers.append(buffer)
        }
        return buffers
    }
}

/// What the follower did and when, filled in from the recognizer's background task.
private final class FollowLog: @unchecked Sendable {
    private let lock = NSLock()
    private var follower: ScriptFollower
    var start: ContinuousClock.Instant?
    private(set) var reached: [Int: Double] = [:]
    private(set) var positions: [(time: Double, position: Int)] = []
    private(set) var updates = 0
    private(set) var moves = 0

    init(script: PrompterScript) { follower = ScriptFollower(script: script) }

    @available(macOS 26, *)
    func hear(_ heard: LiveTranscriber.Heard) {
        lock.lock(); defer { lock.unlock() }
        guard let start else { return }
        let elapsed = start.duration(to: .now)
        let now = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        updates += 1
        let before = follower.position
        if follower.hear(heard.all) {
            moves += 1
            for word in before..<max(before, follower.position) where reached[word] == nil { reached[word] = now }
        }
        positions.append((now, follower.position))
    }
}
