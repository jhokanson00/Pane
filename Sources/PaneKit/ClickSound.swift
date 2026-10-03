import Foundation

/// A mouse-click sound, made in code so there's no audio file to ship. It copies what
/// makes a real mouse button sound clicky: a microswitch snaps twice, a hard bright hit
/// and a quieter one a few milliseconds later, each a burst of high noise with a short
/// high ping, over a small plastic body. Almost all of it is over within 4 ms. Right-clicks
/// are a little lower, so they sound different without sounding like a second click.
public enum ClickSound {
    /// Exports and the Final Cut sound files use 48 kHz, like Pane's recordings.
    public static let sampleRate = 48_000

    /// The sound for one click, mono, starting right on its attack so it lines up with
    /// the moment of the click.
    public static func samples(for button: PointerTrack.Button) -> [Float] {
        button == .right ? right : left
    }

    /// What the Final Cut folder calls each sound's file.
    public static func fileName(for button: PointerTrack.Button) -> String {
        button == .right ? "Right-click.wav" : "Click.wav"
    }

    // Peaks about 16 dB below full scale: a short click this loud sits under typical
    // narration (which peaks around -10 dB) rather than on top of it.
    private static let left = synthesize(pitch: 1, peak: 0.155)
    private static let right = synthesize(pitch: 0.82, peak: 0.14)

    /// One snap of the switch: band-passed noise for the hit, and quickly fading sines for
    /// its ping and the plastic around it.
    private struct Snap {
        var at: Double
        var gain: Double
        var noiseCenter: Double
        var noiseQ: Double
        var noiseDecay: Double
        var tones: [(frequency: Double, decay: Double, level: Double)]
    }

    /// Every snap rises in a tenth of a millisecond, so the click is sharp, then dies away
    /// exponentially. The sound is 60 ms long so nothing is cut off; the last 5 ms ease to
    /// silence so the end can't pop.
    /// - Parameter pitch: Scales every frequency; below 1 for right-clicks.
    private static func synthesize(pitch: Double, peak: Float) -> [Float] {
        let snaps = [
            Snap(at: 0, gain: 1, noiseCenter: 4800 * pitch, noiseQ: 0.8, noiseDecay: 0.0005,
                 tones: [(3900 * pitch, 0.0020, 0.55), (2300 * pitch, 0.0035, 0.35), (950 * pitch, 0.0030, 0.20)]),
            Snap(at: 0.009, gain: 0.45, noiseCenter: 6000 * pitch, noiseQ: 0.9, noiseDecay: 0.0003,
                 tones: [(4600 * pitch, 0.0012, 0.4)]),
        ]
        let rate = Double(sampleRate)
        let count = Int(0.060 * rate)
        let fadeOut = Int(0.005 * rate)
        // A fixed seed: every export and the Final Cut file get exactly the same sound.
        var seed: UInt32 = 0x2545_F491
        func noise() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed >> 8) / Double(1 << 23) - 1
        }

        var output = [Double](repeating: 0, count: count)
        for snap in snaps {
            var filter = BandPass(center: snap.noiseCenter, q: snap.noiseQ, rate: rate)
            let first = Int(snap.at * rate)
            for i in first..<count {
                let t = Double(i - first) / rate
                let attack = min(1, t / 0.0001)
                var value = filter.process(noise() * exp(-t / snap.noiseDecay)) * 2.5
                for tone in snap.tones { value += sin(2 * .pi * tone.frequency * t) * exp(-t / tone.decay) * tone.level }
                output[i] += value * attack * snap.gain
            }
        }
        for i in (count - fadeOut)..<count { output[i] *= Double(count - 1 - i) / Double(fadeOut) }
        let loudest = output.map(abs).max() ?? 1
        return output.map { Float($0 / loudest) * peak }
    }

    /// The sound as a 16-bit mono WAV file, for editors such as Final Cut.
    public static func wav(for button: PointerTrack.Button) -> Data {
        let pcm = samples(for: button).map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count * 2))
        for sample in pcm { append(sample) }
        return data
    }

    /// A two-pole band-pass filter (the usual "biquad" from the Audio EQ Cookbook).
    private struct BandPass {
        private let b0, b2, a1, a2: Double
        private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(center: Double, q: Double, rate: Double) {
            let w = 2 * .pi * center / rate
            let alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha
            b0 = alpha / a0
            b2 = -alpha / a0
            a1 = -2 * cos(w) / a0
            a2 = (1 - alpha) / a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }
    }
}

extension PointerTrack {
    /// The clicks that get a sound in `style`: none unless click sounds are on, and then
    /// every click that's turned on and landed on the video, the same ones that get a
    /// ring. Clicks behind the camera circle still get a sound, since the click really
    /// happened.
    public func clickSounds(style: PointerEffectStyle) -> [Click] {
        guard style.clickSounds else { return [] }
        return clicks.filter { $0.isEnabled && (0...1).contains($0.x) && (0...1).contains($0.y) }
            .sorted { $0.time < $1.time }
    }
}

/// Mixes click sounds into audio at exactly the right samples, one buffer at a time, so
/// a click that straddles two buffers is split across them seamlessly.
public struct ClickSoundMixer: Sendable {
    /// Where each sound starts, in samples from the start of the video.
    let cues: [(start: Int, sound: [Float])]

    public init(clicks: [PointerTrack.Click]) {
        let rate = Double(ClickSound.sampleRate)
        cues = clicks.sorted { $0.time < $1.time }
            .map { (Int(($0.time * rate).rounded()), ClickSound.samples(for: $0.button)) }
    }

    /// Whether any click sounds in `frames` samples starting at sample `start`.
    func overlaps(start: Int, frames: Int) -> Bool {
        cues.contains { $0.start < start + frames && $0.start + $0.sound.count > start }
    }

    /// Adds the clicks that fall in this stretch to every channel of interleaved 48 kHz
    /// samples. Where narration and a click together would clip, the peak is rounded off
    /// instead; everywhere else the narration is left exactly as it was.
    /// - Parameter start: The first sample's position, in samples from the start of the video.
    public func mix(into samples: UnsafeMutableBufferPointer<Float>, channels: Int, start: Int) {
        guard channels > 0 else { return }
        let frames = samples.count / channels
        for cue in cues where cue.start < start + frames && cue.start + cue.sound.count > start {
            let from = max(cue.start, start)
            let to = min(cue.start + cue.sound.count, start + frames)
            for position in from..<to {
                let click = cue.sound[position - cue.start]
                for channel in 0..<channels {
                    let index = (position - start) * channels + channel
                    samples[index] = Self.limit(samples[index] + click)
                }
            }
        }
    }

    /// Unchanged below 0.9; above it, eases toward 1 so loud moments never hard-clip.
    static func limit(_ value: Float) -> Float {
        let size = abs(value)
        guard size > 0.9 else { return value }
        let rounded = 0.9 + 0.1 * tanh((size - 0.9) / 0.1)
        return value < 0 ? -rounded : rounded
    }
}
