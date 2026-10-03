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
        // The camera and markers inside the screen clip are placed on the files' own
        // timeline, so a trim only moves the clips' starts and shortens them.
        let kept = keptFrames
        let cameraKept = kept.clamped(to: 0..<clipFrames)
        let clipStart = kept.lowerBound == 0 ? "" : #" start="\#(time(kept.lowerBound))""#
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
            #"            <sequence format="r1" duration="\#(time(kept.count))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">"#,
            "                <spine>",
            #"                    <asset-clip ref="r2" offset="0s" name="Screen"\#(clipStart) duration="\#(time(kept.count))" tcFormat="NDF"\#(audioTracks > 0 ? #" audioRole="dialogue""# : "")>"#,
        ]
        if camera != nil, !cameraKept.isEmpty {
            lines.append(#"                        <asset-clip ref="r3" lane="1" offset="\#(time(cameraKept.lowerBound))" name="Camera"\#(clipStart) duration="\#(time(cameraKept.count))"/>"#)
        }
        lines += soundEffectClips
        lines += captionLines(lane: camera == nil ? 1 : 2)
        for marker in markers {
            let frame = min(max(Int((marker.time * Double(frameRate)).rounded()), 0), max(frames - 1, 0))
            // Clicks in the trimmed-off parts are left out.
            guard trim == nil || kept.contains(frame) else { continue }
            lines.append(#"                        <marker start="\#(time(frame))" duration="1/\#(frameRate)s" value="\#(escape(marker.label))"/>"#)
        }
        lines += [
            "                    </asset-clip>",
            "                </spine>",
            "            </sequence>",
            "        </project>",
            "    </event>",
            "</fcpxml>",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// The frames on the timeline, after the trim.
    var keptFrames: Range<Int> {
        trim.map { $0.clamped(to: 0..<max(frames, 1)) } ?? 0..<frames
    }

    /// iTT captions connected to the screen clip, on whole frames and never overlapping,
    /// which Final Cut requires within a caption role. Like the markers they're placed on
    /// the screen file's own timeline, so a trim cuts off the parts outside it.
    private func captionLines(lane: Int) -> [String] {
        guard let captions, !captions.cues.isEmpty, frames > 0 else { return [] }
        func time(_ frames: Int) -> String { frames == 0 ? "0s" : "\(frames)/\(frameRate)s" }
        let role = "iTT?captionFormat=ITT.\(captions.language)"
        var lines: [String] = []
        let kept = keptFrames
        var free = kept.lowerBound
        for (index, cue) in captions.cues.enumerated() {
            let start = max(Int((cue.start * Double(frameRate)).rounded()), free)
            let end = min(Int((cue.end * Double(frameRate)).rounded()), kept.upperBound)
            guard end > start else { continue }
            free = end
            let style = "ts\(index + 1)"
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
        text.replacingOccurrences(of: "&", with: "&amp;")
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
    ///   - captions: Added to the project as captions, not drawn into the screen.
    /// - Returns: The project file, to open in Final Cut.
    public static func prepare(
        name: String, screen: URL, camera: URL?, findings: [Finding], effects: [any FrameEffect],
        clicks: [PointerTrack.Click], clickSounds: [PointerTrack.Click] = [], in folder: URL,
        trim: ClosedRange<Double>? = nil, captions: Captions? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
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
        project.captions = captions
        let projectURL = folder.appendingPathComponent(name).appendingPathExtension("fcpxml")
        try project.xml.write(to: projectURL, atomically: true, encoding: .utf8)
        progress(1)
        return projectURL
    }
}
