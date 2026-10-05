import CoreGraphics
import Foundation

/// A piece of text seen in one sampled frame.
public struct TextBox: Codable, Sendable, Equatable {
    public var text: String
    /// Normalized, bottom-left origin.
    public var rect: CGRect
    public var kind: SensitiveKind

    public init(text: String, rect: CGRect, kind: SensitiveKind) {
        self.text = text
        self.rect = rect
        self.kind = kind
    }
}

/// Everything recognized in one sampled frame.
public struct FrameText: Codable, Sendable {
    public var time: Double
    /// Sensitive matches found by the detector.
    public var matches: [TextBox]
    /// Every word on screen, so you can pick extra text to blur after the scan.
    public var words: [TextBox]
}

/// Links per-frame detections into findings that follow text as it moves.
public enum FindingTracker {
    /// - Parameters:
    ///   - frames: Sampled frames sorted by time; only `boxes(frame)` are tracked.
    ///   - interval: Seconds between samples, used to pad start/end times.
    public static func build(
        frames: [FrameText],
        boxes: (FrameText) -> [TextBox],
        interval: Double,
        duration: Double
    ) -> [Finding] {
        struct Track {
            var finding: Finding
            var key: String
            var lastTime: Double
            var lastRect: CGRect
        }

        // Allow a detection to drop out for a sample or two (blurry mid-scroll frames)
        // without splitting it into two findings.
        let maxGap = max(1.0, interval * 3)
        var active: [Track] = []
        var finished: [Finding] = []

        for frame in frames {
            active.removeAll { track in
                guard frame.time - track.lastTime > maxGap else { return false }
                finished.append(track.finding)
                return true
            }

            var used = Set<Int>()
            for box in boxes(frame) {
                let key = normalize(box.text)
                var best: Int?
                var bestScore = 0.0
                for (index, track) in active.enumerated()
                where !used.contains(index) && track.finding.kind == box.kind {
                    let sameText = track.key == key
                    let overlap = iou(track.lastRect, box.rect)
                    // Same text may have scrolled anywhere; different text (an OCR misread)
                    // must be in roughly the same spot.
                    let plausible = sameText ? centerDistance(track.lastRect, box.rect) < 0.6 : overlap > 0.3
                    let score = (sameText ? 1 : 0) + overlap
                    if plausible && score > bestScore {
                        best = index
                        bestScore = score
                    }
                }

                let sample = BoxSample(time: frame.time, rect: box.rect)
                if let best {
                    active[best].finding.samples.append(sample)
                    active[best].lastTime = frame.time
                    active[best].lastRect = box.rect
                    used.insert(best)
                } else {
                    let finding = Finding(kind: box.kind, text: box.text, samples: [sample],
                                          start: frame.time, end: frame.time)
                    active.append(Track(finding: finding, key: key, lastTime: frame.time, lastRect: box.rect))
                    used.insert(active.count - 1)
                }
            }
        }
        finished += active.map(\.finding)

        // Text may have appeared just after the previous sample and stayed until just
        // before the next one, so cover those gaps too.
        let pad = interval + 0.1
        return finished
            .map { finding in
                var finding = finding
                finding.start = max(0, (finding.samples.first?.time ?? 0) - pad)
                finding.end = min(duration, (finding.samples.last?.time ?? 0) + pad)
                return finding
            }
            .sorted { $0.start < $1.start }
    }

    /// Follows one word or phrase through the whole recording, wherever it appears.
    public static func track(text: String, kind: SensitiveKind = .customWord,
                             frames: [FrameText], interval: Double, duration: Double) -> [Finding] {
        let key = wordKey(text)
        return build(
            frames: frames,
            boxes: { frame in
                frame.words
                    .filter { wordKey($0.text) == key }
                    .map { TextBox(text: text, rect: $0.rect, kind: kind) }
            },
            interval: interval,
            duration: duration
        )
    }

    /// Text being typed doesn't match until it's complete ("maria.lo" isn't an email
    /// yet), so it would show until then. Starts each blur at the earliest reading where
    /// the beginning of its text, three characters or more, was already in the same
    /// place, and keeps it up while the text is deleted the same way. The blur holds its
    /// first and last box there, which covers the whole field.
    public static func coveringTyping(_ findings: [Finding], frames: [FrameText], interval: Double,
                                      duration: Double) -> [Finding] {
        findings.map { finding in
            let key = normalize(finding.text)
            guard finding.kind != .manual, key.count > 3,
                  let first = finding.samples.first, let last = finding.samples.last else { return finding }
            func isBeginning(_ word: TextBox, at rect: CGRect) -> Bool {
                let text = normalize(word.text)
                return text.count >= 3 && text.count < key.count && key.hasPrefix(text)
                    && abs(word.rect.minX - rect.minX) < rect.height
                    && abs(word.rect.midY - rect.midY) < rect.height / 2
            }
            var covered = finding
            for frame in frames.reversed() where frame.time < finding.start {
                guard frame.words.contains(where: { isBeginning($0, at: first.rect) }) else { break }
                covered.start = max(0, frame.time - interval)
            }
            for frame in frames where frame.time > finding.end {
                guard frame.words.contains(where: { isBeginning($0, at: last.rect) }) else { break }
                covered.end = min(duration, frame.time + interval)
            }
            return covered
        }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    /// A word as it's written anywhere: "Hokanson", "Hokanson," "(Hokanson)" and
    /// "Hokanson's" are all the same word to blur.
    static func wordKey(_ text: String) -> String {
        var word = normalize(text).trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        for suffix in ["'s", "’s"] where word.hasSuffix(suffix) && word.count > suffix.count {
            word.removeLast(suffix.count)
        }
        // Punctuation on its own stays itself, not "" (which every other mark would match).
        return word.isEmpty ? normalize(text) : word
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let i = intersection.width * intersection.height
        let u = a.width * a.height + b.width * b.height - i
        return u > 0 ? Double(i / u) : 0
    }

    static func centerDistance(_ a: CGRect, _ b: CGRect) -> Double {
        Double(hypot(a.midX - b.midX, a.midY - b.midY))
    }
}
