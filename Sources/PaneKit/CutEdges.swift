import AVFoundation
import Foundation

/// How loud the narration is, every 10 ms, for placing cuts in the quiet between words.
public struct AudioLevels: Equatable, Sendable {
    /// Seconds per level.
    public static let window = 0.01
    /// Loudness of each window, in dB (0 is full scale).
    public var levels: [Float]
    /// Where the narration's first sound is on the video's timeline.
    public var start: Double

    public init(levels: [Float], start: Double = 0) {
        self.levels = levels
        self.start = start
    }

    /// Louder than this is speech. Between the room's quiet (the quietest tenth of the
    /// recording) and the voice (the loudest tenth): within 28 dB of the voice, and at least
    /// 15 dB over the quiet.
    public var speechThreshold: Float {
        let sorted = levels.sorted()
        guard !sorted.isEmpty else { return -50 }
        let quiet = sorted[sorted.count / 10], voice = sorted[sorted.count * 9 / 10]
        return max(quiet + 15, voice - 28)
    }

    /// Louder than this is some sound, not the room: 12 dB over the quiet.
    public var soundThreshold: Float {
        let sorted = levels.sorted()
        guard !sorted.isEmpty else { return -60 }
        return min(sorted[sorted.count / 10] + 12, speechThreshold)
    }

    /// The window holding `time`.
    func index(_ time: Double) -> Int { Int(((time - start) / Self.window).rounded(.down)) }
    func time(_ index: Int) -> Double { start + Double(index) * Self.window }

    /// Reads the first sound track (the microphone in Pane's recordings).
    public static func read(url: URL) async throws -> AudioLevels {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CaptionError.noAudio }
        let rate = 16_000
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw ExportError.failed(reader.error) }

        let perWindow = Int(Double(rate) * window)
        var levels: [Float] = []
        var sum: Float = 0, count = 0
        var start: Double?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = sample.dataBuffer else { continue }
            if start == nil { start = sample.presentationTimeStamp.seconds }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            floats.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            for value in floats {
                sum += value * value
                count += 1
                if count == perWindow {
                    levels.append(10 * log10(max(sum / Float(count), 1e-10)))
                    sum = 0
                    count = 0
                }
            }
        }
        if reader.status == .failed { throw ExportError.failed(reader.error) }
        let begin = start ?? 0
        return AudioLevels(levels: levels, start: begin.isFinite ? begin : 0)
    }
}

/// Where cuts go so the joins sound natural.
///
/// Cuts found from the words (retakes, later pauses and ums) are timed by speech
/// recognition, which can be a tenth of a second off: a cut ending at the retake's first
/// word can clip its start, and one starting at the flubbed try's first word can leave a
/// syllable of it in. So each edge moves to where the sound really starts. The silence
/// before the flubbed try is all kept (the screen may be busy during it), and some of the
/// silence before the retake is kept as a lead-in, the breathing room editors leave around
/// speech (auto-editor's margin, Recut's padding). Nothing is added: only silence already
/// there is kept.
public enum CutEdges {
    /// How much of the silence before a retake is kept.
    public enum Pause: String, CaseIterable, Identifiable, Sendable {
        case short, medium, long
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
        /// The settings key it's remembered under.
        public static let key = "cutPause"
        /// The one chosen last, or medium.
        public static var saved: Pause {
            UserDefaults.standard.string(forKey: key).flatMap(Pause.init(rawValue:)) ?? .medium
        }
        public var seconds: Double {
            switch self {
            case .short: 0.1
            case .medium: 0.25
            case .long: 0.5
            }
        }
    }

    /// Sound shorter than this isn't speech (a mouse click, a tap on the desk).
    static let shortestSound = 0.04
    /// How far an edge may move to find where the sound starts.
    static let reach = 0.35
    /// How far an edge stays from a sound's start.
    static let margin = 0.02

    /// The cuts with their edges just before the sounds they cut and keep, and `pause` of
    /// the silence before each retake kept. Cuts that touch or overlap are joined first, so
    /// one join is made, not two.
    /// - Parameter words: The narration, so an edge never moves back past the word before.
    public static func placed(_ cuts: [ClosedRange<Double>], levels: AudioLevels, words: [CaptionWord],
                              pause: Pause) -> [ClosedRange<Double>] {
        let loud = levels.speechThreshold, sound = levels.soundThreshold
        return VideoEdit.merged(cuts).compactMap { cut in
            let flub = soundStart(near: cut.lowerBound, levels: levels, loud: loud, sound: sound,
                                  after: wordEnd(before: cut.lowerBound, words: words))
            let retake = soundStart(near: cut.upperBound, levels: levels, loud: loud, sound: sound,
                                    after: wordEnd(before: cut.upperBound, words: words))
            let quiet = retake - silenceStart(before: retake, levels: levels, threshold: loud)
            let lead = min(pause.seconds, max(0, quiet - margin))
            let start = flub - margin, end = retake - margin - lead
            return end - start >= VideoEdit.shortestCut ? start...end : nil
        }
    }

    /// Where the sound of the words at `time` begins: the speech found by `onset`, and any
    /// softer sound running into it (a breath, an "s" or "h").
    static func soundStart(near time: Double, levels: AudioLevels, loud: Float, sound: Float, after: Double?) -> Double {
        let speech = onset(near: time, levels: levels, threshold: loud, after: after)
        let earliest = max(0, levels.index(max(speech - reach, after ?? -.infinity)))
        var index = min(levels.index(speech), levels.levels.count)
        while index > earliest, levels.levels[index - 1] > sound { index -= 1 }
        return min(speech, levels.time(index))
    }

    /// Where speech really starts near `time`: back to the start of the sound if it's
    /// already going, or on to the next sound if it's quiet there. Never before `after`.
    static func onset(near time: Double, levels: AudioLevels, threshold: Float, after: Double?) -> Double {
        let count = levels.levels.count
        let at = levels.index(time)
        guard at >= 0, at < count else { return time }
        let earliest = max(0, levels.index(max(time - reach, after ?? -.infinity)))
        let latest = min(count - 1, levels.index(time + reach))
        let run = Int((shortestSound / AudioLevels.window).rounded())
        func loud(_ index: Int) -> Bool { levels.levels[index] > threshold }
        func sound(at index: Int) -> Bool {
            index + run <= count && (index..<index + run).allSatisfy(loud)
        }

        if loud(at) || (at > 0 && loud(at - 1)) {
            var index = at
            while index > earliest, loud(index - 1) { index -= 1 }
            return levels.time(index)
        }
        if let next = (at...latest).first(where: sound) { return levels.time(next) }
        return time
    }

    /// Where the silence before `time` begins: back over quiet windows (and sounds too short
    /// to be speech) to the end of the last speech, at most a few seconds.
    static func silenceStart(before time: Double, levels: AudioLevels, threshold: Float) -> Double {
        let run = Int((shortestSound / AudioLevels.window).rounded())
        var index = min(levels.index(time), levels.levels.count)
        let earliest = max(0, levels.index(time - 3))
        var loudRun = 0
        while index > earliest {
            if levels.levels[index - 1] > threshold {
                loudRun += 1
                if loudRun >= run { return levels.time(index - 1 + loudRun) }
            } else {
                loudRun = 0
            }
            index -= 1
        }
        return levels.time(index)
    }

    /// The end of the last word that starts before `time`, if there's one.
    static func wordEnd(before time: Double, words: [CaptionWord]) -> Double? {
        words.last { $0.start < time - 0.02 }.map { min($0.end, time) }
    }
}

/// Very short fades where kept parts of a cut copy meet, so a join never clicks: the
/// sentence before fades out over 10 ms and the one after fades in (Descript calls these
/// microfades). Positions are samples at 48 kHz on the recording's own timeline.
public struct JoinFades: Equatable, Sendable {
    public static let length = 0.01
    /// Where each fade out ends.
    var outs: [Int] = []
    /// Where each fade in starts.
    var ins: [Int] = []
    private var samples: Int { Int(Self.length * Double(ClickSound.sampleRate)) }

    public init(edit: VideoEdit, duration: Double) {
        let parts = edit.kept(duration: duration)
        let rate = Double(ClickSound.sampleRate)
        for (left, right) in zip(parts, parts.dropFirst()) {
            outs.append(Int((left.upperBound * rate).rounded()))
            ins.append(Int((right.lowerBound * rate).rounded()))
        }
    }

    public var isEmpty: Bool { outs.isEmpty }

    func overlaps(start: Int, frames: Int) -> Bool {
        let end = start + frames
        return outs.contains { $0 > start && $0 - samples < end } || ins.contains { $0 < end && $0 + samples > start }
    }

    /// Fades interleaved samples whose first frame is at `start`.
    func apply(to buffer: UnsafeMutableBufferPointer<Float>, channels: Int, start: Int) {
        let frames = buffer.count / channels, length = samples
        func scale(from first: Int, to last: Int, gain: (Int) -> Float) {
            for position in max(first, start)..<min(last, start + frames) {
                let value = gain(position), frame = (position - start) * channels
                for channel in 0..<channels { buffer[frame + channel] *= value }
            }
        }
        for end in outs where end > start && end - length < start + frames {
            scale(from: end - length, to: end) { Float(end - $0) / Float(length) }
        }
        for begin in ins where begin < start + frames && begin + length > start {
            scale(from: begin, to: begin + length) { Float($0 - begin + 1) / Float(length) }
        }
    }
}
