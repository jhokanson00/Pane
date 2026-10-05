import Foundation

extension FinalCutProject {
    /// A short sound, such as the click sound, connected below the screen at each of its
    /// moments with the "effects" role, so an editor can turn them all down at once, or
    /// move or delete any one.
    public struct SoundEffect: Sendable {
        public var name: String
        /// A mono 48 kHz sound file.
        public var file: URL
        /// The sound's length, in samples.
        public var samples: Int
        /// Seconds into the video.
        public var times: [Double]

        public init(name: String, file: URL, samples: Int, times: [Double]) {
            self.name = name
            self.file = file
            self.samples = samples
            self.times = times
        }

        /// Writes the click sounds `clicks` need into `folder`, one file for left-clicks
        /// and one for right-clicks, and places each at its clicks.
        static func clicks(_ clicks: [PointerTrack.Click], in folder: URL) throws -> [SoundEffect] {
            var effects: [SoundEffect] = []
            for (button, name) in [(PointerTrack.Button.left, "Click"), (.right, "Right-click")] {
                let times = clicks.filter { ($0.button == .right) == (button == .right) }.map(\.time).sorted()
                guard !times.isEmpty else { continue }
                let file = folder.appendingPathComponent(ClickSound.fileName(for: button))
                try ClickSound.wav(for: button).write(to: file, options: .atomic)
                effects.append(SoundEffect(name: name, file: file, samples: ClickSound.samples(for: button).count,
                                           times: times))
            }
            return effects
        }
    }

    /// Sounds are placed to the sample, not the frame, so each click is heard right when
    /// it happens. Final Cut allows this for audio-only clips.
    private func sampleTime(_ samples: Int) -> String {
        samples == 0 ? "0s" : "\(samples)/\(ClickSound.sampleRate)s"
    }

    /// Resource ids after the format, screen and camera.
    private func soundEffectID(_ index: Int) -> String { "r\(4 + index)" }

    var soundEffectAssets: [String] {
        soundEffects.enumerated().flatMap { index, sound in
            [
                #"        <asset id="\#(soundEffectID(index))" name="\#(escape(sound.name))" start="0s" duration="\#(sampleTime(sound.samples))" hasAudio="1" audioSources="1" audioChannels="1" audioRate="48000">"#,
                #"            <media-rep kind="original-media" src="\#(escape(sound.file.absoluteString))"/>"#,
                "        </asset>",
            ]
        }
    }

    /// One connected clip per moment, below the screen. Sounds that would overlap go on
    /// separate lanes, so none hides another.
    func soundEffectClips(in kept: Range<Int>) -> [String] {
        let rate = Double(ClickSound.sampleRate)
        // Placed on the screen file's own timeline, like the markers, so a trim or cut
        // only leaves out the sounds in the parts left out.
        func sample(_ frame: Int) -> Int { Int((Double(frame) / Double(max(frameRate, 1)) * rate).rounded()) }
        let start = sample(kept.lowerBound)
        let end = sample(kept.upperBound)
        let placed = soundEffects.enumerated().flatMap { index, sound in
            sound.times.map { (start: Int(($0 * rate).rounded()), index: index, sound: sound) }
        }
        .filter { $0.start >= start && $0.start < end }
        .sorted { $0.start < $1.start }

        var laneEnds: [Int] = []
        return placed.map { clip in
            let lane = laneEnds.firstIndex { $0 <= clip.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(0) }
            laneEnds[lane] = clip.start + clip.sound.samples
            return #"                        <asset-clip ref="\#(soundEffectID(clip.index))" lane="\#(-1 - lane)" offset="\#(sampleTime(clip.start))" name="\#(escape(clip.sound.name))" duration="\#(sampleTime(clip.sound.samples))" audioRole="effects"/>"#
        }
    }
}
