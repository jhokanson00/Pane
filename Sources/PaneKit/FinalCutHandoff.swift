import AVFoundation

/// A Final Cut Pro project for one recording, as FCPXML: the screen on the main
/// timeline, the camera connected above it when it was recorded separately, and a
/// marker at every click so the steps of a tutorial are easy to find.
public struct FinalCutProject: Sendable {
    public var name: String
    public var width: Int
    public var height: Int
    public var frameRate: Int
    /// The screen's length, in frames.
    public var frames: Int
    public var screen: URL
    public var audioTracks: Int
    public var audioChannels: Int
    /// The camera over transparency, the same size and length as the screen.
    public var camera: URL?
    public var cameraFrames: Int
    /// Seconds into the video, and what to call each one.
    public var markers: [(time: Double, label: String)]
    /// The frames kept on the timeline; nil keeps them all. The files stay whole, so the
    /// trim can still be undone or changed in Final Cut by dragging the clip's ends.
    public var trim: Range<Int>?
    /// Frames left out from inside the trim (retakes): the screen becomes one clip per
    /// part kept, back to back, and dragging a clip's end brings a cut part back.
    public var cuts: [Range<Int>] = []
    /// Frames kept on the timeline but set on a layer of their own (retakes kept for
    /// deciding in Final Cut): a gap in the main timeline with the screen and camera
    /// connected above it, in the Retakes roles. Deleting the gap removes the retake and
    /// closes up; Overwrite to Primary Storyline keeps it.
    public var setAside: [Range<Int>] = []
    /// Sounds such as the click sound, connected below the screen at their moments.
    public var soundEffects: [SoundEffect] = []
    /// Captions from the narration. Final Cut keeps them as a caption role, where they
    /// can be edited, turned on or off, burned in, or exported as a file.
    public var captions: Captions?

    public init(name: String, width: Int, height: Int, frameRate: Int, frames: Int, screen: URL,
                audioTracks: Int, audioChannels: Int, camera: URL?, cameraFrames: Int,
                markers: [(time: Double, label: String)], trim: Range<Int>? = nil, soundEffects: [SoundEffect] = []) {
        self.name = name
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.frames = frames
        self.screen = screen
        self.audioTracks = audioTracks
        self.audioChannels = audioChannels
        self.camera = camera
        self.cameraFrames = cameraFrames
        self.markers = markers
        self.trim = trim
        self.soundEffects = soundEffects
    }

    /// Version 1.13 opens in Final Cut Pro 11 and later.
    public static let version = "1.13"

    public var xml: String {
        func time(_ frames: Int) -> String { frames == 0 ? "0s" : "\(frames)/\(frameRate)s" }
        let audio = audioTracks > 0
            ? #" hasAudio="1" audioSources="\#(audioTracks)" audioChannels="\#(audioChannels)" audioRate="48000""#
            : ""
        let clipFrames = camera == nil ? frames : min(frames, cameraFrames)
        // The camera and markers inside each screen clip are placed on the files' own
        // timeline, so a trim or cut only moves the clips' starts and shortens them.
        let pieces = timelinePieces
        let total = pieces.reduce(0) { $0 + $1.frames.count }
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            "<!DOCTYPE fcpxml>",
            "",
            #"<fcpxml version="\#(Self.version)">"#,
            "    <resources>",
            #"        <format id="r1" frameDuration="1/\#(frameRate)s" width="\#(width)" height="\#(height)" colorSpace="1-1-1 (Rec. 709)"/>"#,
            #"        <asset id="r2" name="Screen" start="0s" duration="\#(time(frames))" hasVideo="1" format="r1" videoSources="1"\#(audio)>"#,
            #"            <media-rep kind="original-media" src="\#(escape(screen.absoluteString))"/>"#,
            "        </asset>",
        ]
        if let camera {
            lines += [
                #"        <asset id="r3" name="Camera" start="0s" duration="\#(time(cameraFrames))" hasVideo="1" format="r1" videoSources="1">"#,
                #"            <media-rep kind="original-media" src="\#(escape(camera.absoluteString))"/>"#,
                "        </asset>",
            ]
        }
        lines += soundEffectAssets
        lines += [
            "    </resources>",
            #"    <event name="Pane">"#,
            #"        <project name="\#(escape(name))">"#,
            #"            <sequence format="r1" duration="\#(time(total))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">"#,
            "                <spine>",
        ]
        var offset = 0
        for (index, piece) in pieces.enumerated() {
            let kept = piece.frames
            let cameraKept = kept.clamped(to: 0..<clipFrames)
            let clipStart = kept.lowerBound == 0 ? "" : #" start="\#(time(kept.lowerBound))""#
            func camera(lane: Int, role: String) -> [String] {
                guard self.camera != nil, !cameraKept.isEmpty else { return [] }
                return [#"                        <asset-clip ref="r3" lane="\#(lane)" offset="\#(time(cameraKept.lowerBound))" name="Camera"\#(cameraKept.lowerBound == 0 ? "" : #" start="\#(time(cameraKept.lowerBound))""#) duration="\#(time(cameraKept.count))"\#(role)/>"#]
            }
            if piece.setAside {
                // A gap in the main timeline, on the files' own timeline like a screen clip,
                // with the retake's screen, camera, sounds, captions and clicks connected to it.
                let roles = #" videoRole="\#(Self.retakeVideoRole)""# + (audioTracks > 0 ? #" audioRole="\#(Self.retakeAudioRole)""# : "")
                lines.append(#"                    <gap name="Retake" offset="\#(time(offset))" start="\#(time(kept.lowerBound))" duration="\#(time(kept.count))">"#)
                lines.append(#"                        <asset-clip ref="r2" lane="1" offset="\#(time(kept.lowerBound))" name="Retake"\#(clipStart) duration="\#(time(kept.count))"\#(roles)/>"#)
                lines += camera(lane: 2, role: #" videoRole="\#(Self.retakeVideoRole)""#)
                lines += soundEffectClips(in: kept)
                lines += captionLines(lane: self.camera == nil ? 2 : 3, in: kept, clip: index)
                lines += markerLines(in: kept)
                lines.append("                    </gap>")
            } else {
                lines.append(#"                    <asset-clip ref="r2" offset="\#(time(offset))" name="Screen"\#(clipStart) duration="\#(time(kept.count))" tcFormat="NDF"\#(audioTracks > 0 ? #" audioRole="dialogue""# : "")>"#)
                lines += camera(lane: 1, role: "")
                lines += soundEffectClips(in: kept)
                lines += captionLines(lane: self.camera == nil ? 1 : 2, in: kept, clip: index)
                lines += markerLines(in: kept)
                lines.append("                    </asset-clip>")
            }
            offset += kept.count
        }
        lines += [
            "                </spine>",
            "            </sequence>",
            "        </project>",
            "    </event>",
            "</fcpxml>",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// The roles retakes set aside are in, so the timeline index can hide or show them all.
    static let retakeVideoRole = "video.Retakes"
    static let retakeAudioRole = "dialogue.Retakes"

    /// A marker at each click in `kept`, on the files' own timeline. Clicks in the parts
    /// left out get none.
    private func markerLines(in kept: Range<Int>) -> [String] {
        func time(_ frames: Int) -> String { frames == 0 ? "0s" : "\(frames)/\(frameRate)s" }
        return markers.compactMap { marker in
            let frame = min(max(Int((marker.time * Double(frameRate)).rounded()), 0), max(frames - 1, 0))
            guard kept.contains(frame) else { return nil }
            return #"                        <marker start="\#(time(frame))" duration="1/\#(frameRate)s" value="\#(escape(marker.label))"/>"#
        }
    }

    /// The parts on the timeline in order, each either in the main timeline or set aside on
    /// a layer of its own.
    var timelinePieces: [(frames: Range<Int>, setAside: Bool)] {
        var pieces: [(frames: Range<Int>, setAside: Bool)] = []
        let aside = setAside.sorted { $0.lowerBound < $1.lowerBound }
        for kept in keptSegments {
            var start = kept.lowerBound
            for range in aside where range.upperBound > start && range.lowerBound < kept.upperBound {
                let low = max(range.lowerBound, start), high = min(range.upperBound, kept.upperBound)
                if low > start { pieces.append((start..<low, false)) }
                if high > low { pieces.append((low..<high, true)) }
                start = max(start, high)
            }
            if start < kept.upperBound { pieces.append((start..<kept.upperBound, false)) }
        }
        return pieces
    }

    /// The frames on the timeline, after the trim.
    var keptFrames: Range<Int> {
        trim.map { $0.clamped(to: 0..<max(frames, 1)) } ?? 0..<frames
    }

    /// The parts kept, in order: the trim less the cuts.
    var keptSegments: [Range<Int>] {
        var parts: [Range<Int>] = []
        var start = keptFrames.lowerBound
        for cut in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) where cut.upperBound > start {
            if cut.lowerBound > start { parts.append(start..<min(cut.lowerBound, keptFrames.upperBound)) }
            start = max(start, cut.upperBound)
        }
        if start < keptFrames.upperBound { parts.append(start..<keptFrames.upperBound) }
        return parts.filter { !$0.isEmpty }.isEmpty ? [keptFrames] : parts.filter { !$0.isEmpty }
    }

    /// iTT captions connected to the screen clip, on whole frames and never overlapping,
    /// which Final Cut requires within a caption role. Like the markers they're placed on
    /// the screen file's own timeline, so a trim cuts off the parts outside it.
    private func captionLines(lane: Int, in kept: Range<Int>, clip: Int) -> [String] {
        guard let captions, !captions.cues.isEmpty, frames > 0 else { return [] }
        func time(_ frames: Int) -> String { frames == 0 ? "0s" : "\(frames)/\(frameRate)s" }
        let role = "iTT?captionFormat=ITT.\(captions.language)"
        var lines: [String] = []
        var free = kept.lowerBound
        for (index, cue) in captions.cues.enumerated() {
            let start = max(Int((cue.start * Double(frameRate)).rounded()), free)
            let end = min(Int((cue.end * Double(frameRate)).rounded()), kept.upperBound)
            guard end > start else { continue }
            free = end
            // Unique across clips: a caption across a cut is in two of them.
            let style = clip == 0 ? "ts\(index + 1)" : "ts\(clip + 1)-\(index + 1)"
            let text = cue.lines.map(escape).joined(separator: "&#10;")
            lines += [
                #"                        <caption lane="\#(lane)" offset="\#(time(start))" name="\#(escape(cue.lines.joined(separator: " ")))" duration="\#(time(end - start))" role="\#(escape(role))">"#,
                #"                            <text placement="bottom"><text-style ref="\#(style)">\#(text)</text-style></text>"#,
                #"                            <text-style-def id="\#(style)"><text-style font=".SF NS Text" fontSize="13" fontFace="Regular" fontColor="1 1 1 1" backgroundColor="0 0 0 1"/></text-style-def>"#,
                "                        </caption>",
            ]
        }
        return lines
    }

    func escape(_ text: String) -> String {
        // XML 1.0 can't hold most control characters at all, so they're left out.
        let allowed = text.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        return String(String.UnicodeScalarView(allowed))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Gets a recording ready for Final Cut: the screen exported with its blurs and
/// pointer effects, the camera clip beside it, and a project that lays them out.
public enum FinalCutHandoff {
    /// - Parameters:
    ///   - screen: The screen without the camera if it was kept separately, otherwise the
    ///     recording itself.
    ///   - camera: The camera over transparency, if it was kept separately.
    ///   - folder: Where the files go. Final Cut uses them from here.
    ///   - clickSounds: Clicks that get a click sound, as clips of their own rather than
    ///     mixed into the screen's audio, so they can be adjusted or deleted.
    ///   - trim: The part to keep, in seconds. The files stay whole and the project
    ///     trims them, so the cut parts can be brought back in Final Cut.
    ///   - cuts: Parts to leave out from inside the trim (retakes), in seconds; the project
    ///     leaves them out the same way.
    ///   - setAside: Parts kept but put on a layer of their own (retakes kept, to decide
    ///     on in Final Cut), in seconds.
    ///   - captions: Added to the project as captions, not drawn into the screen.
    /// - Returns: The project file, to open in Final Cut.
    public static func prepare(
        name: String, screen: URL, camera: URL?, findings: [Finding], effects: [any FrameEffect],
        clicks: [PointerTrack.Click], clickSounds: [PointerTrack.Click] = [], in folder: URL,
        trim: ClosedRange<Double>? = nil, cuts: [ClosedRange<Double>] = [], setAside: [ClosedRange<Double>] = [],
        captions: Captions? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let screenOut = folder.appendingPathComponent("Screen.mp4")
        try await RedactionExporter.export(source: screen, to: screenOut, findings: findings, effects: effects,
                                           progress: { progress($0 * 0.97) })
        var cameraOut: URL?
        if let camera, fileManager.fileExists(atPath: camera.path) {
            let destination = folder.appendingPathComponent("Camera.mov")
            try? fileManager.removeItem(at: destination)
            // A copy on the same disk is a clone: instant, and no extra space.
            try fileManager.copyItem(at: camera, to: destination)
            cameraOut = destination
        }

        let asset = AVURLAsset(url: screenOut)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let size = try await video.load(.naturalSize)
        let rate = Int(try await video.load(.nominalFrameRate).rounded())
        let frameRate = rate > 0 ? rate : 30
        let frames = Int((try await asset.load(.duration).seconds * Double(frameRate)).rounded(.down))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var channels = 2
        if let first = audio.first, let format = try await first.load(.formatDescriptions).first,
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
            channels = Int(description.pointee.mChannelsPerFrame)
        }
        var cameraFrames = frames
        if let cameraOut {
            cameraFrames = Int((try await AVURLAsset(url: cameraOut).load(.duration).seconds * Double(frameRate))
                .rounded(.down))
        }

        var project = FinalCutProject(
            name: name, width: Int(size.width), height: Int(size.height), frameRate: frameRate, frames: frames,
            screen: screenOut, audioTracks: audio.count, audioChannels: channels, camera: cameraOut,
            cameraFrames: cameraFrames,
            markers: clicks.filter(\.isEnabled).map { click in
                (click.time, click.button == .right ? "Right-click" : click.isHand ? "Click a link or button" : "Click")
            },
            trim: Trim.normalized(trim, duration: Double(frames) / Double(frameRate))
                .map { Trim.frames($0, frameRate: frameRate, totalFrames: frames) },
            soundEffects: try FinalCutProject.SoundEffect.clicks(clickSounds, in: folder)
        )
        func frameRange(_ range: ClosedRange<Double>) -> Range<Int> {
            Int((range.lowerBound * Double(frameRate)).rounded())..<Int((range.upperBound * Double(frameRate)).rounded())
        }
        project.cuts = cuts.map(frameRange)
        project.setAside = setAside.map(frameRange)
        project.captions = captions
        let projectURL = folder.appendingPathComponent(name).appendingPathExtension("fcpxml")
        try project.xml.write(to: projectURL, atomically: true, encoding: .utf8)
        progress(1)
        return projectURL
    }
}
