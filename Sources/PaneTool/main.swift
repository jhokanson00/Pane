// Developer tool for testing Pane's blur pipeline without the app.
//
//   swift run pane-tool sample out.mp4            make a test video with fake sensitive text
//   swift run pane-tool scan video.mp4            list what would be blurred
//   swift run pane-tool export video.mp4 out.mp4  scan, then write a blurred copy
//   swift run pane-tool frame video.mp4 2.5 out.png  save one frame as an image
//   swift run pane-tool blur in.png out.png x y w h [--circle]  try the blur on a still image
//   swift run pane-tool check                     measure how closely blurs follow the sample's scrolling
//   swift run pane-tool pointer-demo out.mp4 [blue]  export the sample with scripted pointer effects
//   swift run pane-tool pointer-frames video.mp4 dir  mark the recorded pointer on its fastest frames
//   swift run pane-tool shortcuts-demo out.mp4 [--camera]  export the sample with scripted shortcut badges
//   swift run pane-tool shortcuts video.mp4       list the keyboard shortcuts saved with a recording
//   swift run pane-tool audit video.mp4 [from to]  find sensitive text the blurs miss
//   swift run pane-tool readings video.mp4 from to  show what the scan read, and the items it made
//   swift run pane-tool readable video.mp4         sensitive text still readable in a finished export
//   swift run pane-tool trim video.mp4 out.mp4 from to  export only from..to, with pointer effects
//   swift run pane-tool zoom-export video.mp4 out.mp4 [subtle|strong]  pointer effects plus zoom toward clicks
//   swift run pane-tool captions video.mp4 [out.mp4]  captions from the narration as SRT; optionally burned into a copy
//   swift run pane-tool follow audio.wav script.txt  how closely the teleprompter follows the narration, live
//   swift run pane-tool retakes video.mp4 script.txt  the retakes Pane would cut, from the narration and script
import AppKit
import AVFoundation
import PaneKit

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func formatTime(_ t: Double) -> String { String(format: "%.2fs", t) }

switch args.first {
case "sample":
    guard args.count == 2 else { fail("usage: pane-tool sample <out.mp4>") }
    try await SampleVideo.write(to: URL(fileURLWithPath: args[1]))
    print("Wrote \(args[1])")

case "scan":
    guard args.count == 2 else { fail("usage: pane-tool scan <video>") }
    let start = Date()
    let result = try await RecordingScanner.scan(url: URL(fileURLWithPath: args[1]), options: .init())
    print("Scanned \(result.frames.count) frames in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    for finding in result.findings {
        let first = finding.samples.first!.rect
        print("\(finding.kind.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) "
              + "\(formatTime(finding.start))–\(formatTime(finding.end))  "
              + "\(finding.samples.count) samples  \"\(finding.text)\"  "
              + String(format: "first box x=%.2f y=%.2f w=%.2f h=%.2f", first.minX, first.minY, first.width, first.height))
    }

case "export":
    guard args.count == 3 else { fail("usage: pane-tool export <video> <out.mp4>") }
    let source = URL(fileURLWithPath: args[1])
    let result = try await RecordingScanner.scan(url: source, options: .init())
    print("Found \(result.findings.count) items")
    let start = Date()
    try await RedactionExporter.export(source: source, to: URL(fileURLWithPath: args[2]), findings: result.findings)
    print("Exported \(args[2]) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")

case "frame":
    guard args.count == 4, let time = Double(args[2]) else { fail("usage: pane-tool frame <video> <seconds> <out.png>") }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: args[1])))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
    print("Wrote \(args[3])")

case "blur":
    let circle = args.last == "--circle"
    let blurArgs = circle ? Array(args.dropLast()) : args
    let numbers = blurArgs.dropFirst(3).compactMap(Double.init)
    guard blurArgs.count >= 7, numbers.count == blurArgs.count - 3, numbers.count % 4 == 0,
          let image = CIImage(contentsOf: URL(fileURLWithPath: blurArgs[1])) else {
        fail("usage: pane-tool blur <in.png> <out.png> x y w h [x y w h …] [--circle]  (normalized, bottom-left origin)")
    }
    let areas = stride(from: 0, to: numbers.count, by: 4).map {
        (rect: CGRect(x: numbers[$0], y: numbers[$0 + 1], width: numbers[$0 + 2], height: numbers[$0 + 3]),
         shape: circle ? BlurShape.ellipse : .rectangle)
    }
    let output = Redaction.apply(to: image, areas: areas)
    let context = CIContext()
    try context.writePNGRepresentation(of: output, to: URL(fileURLWithPath: blurArgs[2]), format: .RGBA8,
                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    print("Wrote \(blurArgs[2])")

case "check":
    // Scans a fresh sample video and compares each blur's position on every frame with
    // where its line of text really is.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pane-check.mp4")
    try await SampleVideo.write(to: url)
    let result = try await RecordingScanner.scan(url: url, options: .init())
    let height = Double(SampleVideo.height)
    var worst = 0.0
    var leaks = 0
    for finding in result.findings {
        let times = stride(from: 0.0, to: SampleVideo.duration, by: 1 / Double(SampleVideo.fps))
        let active = times.filter { finding.coverRect(at: $0, aspect: 16 / 9) != nil }
        guard !active.isEmpty else { continue }
        // The blur's offset from the text should stay constant as the text moves.
        let offsets = active.map { finding.coverRect(at: $0, aspect: 16 / 9)!.minY * height - SampleVideo.scroll(at: $0) }
        let center = offsets.sorted()[offsets.count / 2]
        let errors = offsets.map { abs($0 - center) }
        let maxError = errors.max() ?? 0
        worst = max(worst, maxError)
        print("\(finding.kind.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) "
              + "\(formatTime(finding.start))–\(formatTime(finding.end))  \(finding.samples.count) samples  "
              + String(format: "max off %.1f px, mean %.1f px", maxError, errors.reduce(0, +) / Double(errors.count)))
        let drifting = zip(active, errors).filter { $0.1 > 2 }
        if !drifting.isEmpty {
            print("  more than 2 px off at " + drifting.map { String(format: "%.2fs (%.1f)", $0.0, $0.1) }.joined(separator: ", "))
        }
    }
    // Frames where any part of a sensitive line is on screen but not covered, and
    // "pops": frames where the set of blurs on a visible line changes.
    var pops = 0
    for (index, line) in SampleVideo.lines.enumerated() {
        let covering = result.findings.filter { line.contains($0.text) }
        guard !covering.isEmpty else { continue }
        var missed: [Double] = []
        var previous: [UUID]?
        for t in stride(from: 0.0, to: SampleVideo.duration, by: 1 / Double(SampleVideo.fps)) {
            // The letters span roughly 7–29 px above the line's drawing point.
            let y = SampleVideo.lineY(index, at: t)
            let low = max(y + 7, 0), high = min(y + 29, height)
            guard high - low >= 3 else { previous = nil; continue }
            let active = covering.filter { $0.coverRect(at: t, aspect: 16 / 9) != nil }
            let covered = active.contains { f in
                let r = f.coverRect(at: t, aspect: 16 / 9)!
                return r.minY * height <= low + 1 && r.maxY * height >= high - 1
            }
            if !covered { missed.append(t) }
            let ids = active.map(\.id)
            if let previous, previous != ids { pops += 1 }
            previous = ids
        }
        leaks += missed.count
        if !missed.isEmpty { print("UNCOVERED \"\(line)\" on \(missed.count) frames: \(missed.map { formatTime($0) })") }
    }
    print("Pops while visible: \(pops)")
    print(String(format: "Worst: %.1f px off. Unblurred frames: %d", worst, leaks))

case "pointer-demo":
    guard args.count >= 2 else { fail("usage: pane-tool pointer-demo <out.mp4> [color]") }
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("pane-pointer-demo.mp4")
    try await SampleVideo.write(to: source)
    var style = PointerEffectStyle()
    if args.count > 2, let tint = PointerEffectStyle.Tint(rawValue: args[2]) { style.tint = tint }
    let renderer = PointerRenderer(track: PointerDemo.track, style: style,
                                   videoSize: CGSize(width: SampleVideo.width, height: SampleVideo.height))
    try await RedactionExporter.export(source: source, to: URL(fileURLWithPath: args[1]), findings: [], effects: [renderer].compactMap { $0 })
    print("Wrote \(args[1])")

case "click-demo", "click-export", "click-finalcut", "click-check":
    try await ClickSoundTool.run(args)

case "shortcuts-demo":
    // The sample video with scripted keyboard shortcut badges (and a camera circle in
    // their way with --camera). Look at its frames with `frame`.
    guard args.count >= 2 else { fail("usage: pane-tool shortcuts-demo <out.mp4> [--camera]") }
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("pane-shortcuts-demo.mp4")
    try await SampleVideo.write(to: source)
    let badges = ShortcutBadgeRenderer(track: ShortcutDemo.track(camera: args.contains("--camera")),
                                       videoSize: CGSize(width: SampleVideo.width, height: SampleVideo.height))
    try await RedactionExporter.export(source: source, to: URL(fileURLWithPath: args[1]), findings: [],
                                       effects: [badges].compactMap { $0 })
    print("Wrote \(args[1])")

case "shortcuts":
    // The keyboard shortcuts saved with a recording.
    guard args.count == 2 else { fail("usage: pane-tool shortcuts <video>") }
    guard let track = ShortcutTrack.load(from: URL(fileURLWithPath: args[1])) else { fail("No shortcuts in \(args[1])") }
    for press in track.presses { print(formatTime(press.time) + "  " + press.shortcut.label) }
    print("\(track.presses.count) shortcuts")

case "audit":
    guard args.count == 2 || args.count == 4 else { fail("usage: pane-tool audit <video> [from to]") }
    let url = URL(fileURLWithPath: args[1])
    let ranges = args.count == 4 ? [Double(args[2])!...Double(args[3])!] : nil
    // The scan already checks the even frames and fixes what it misses, so check the
    // odd ones, which it never looked at. PANE_NO_VERIFY=1 audits the plain scan.
    let verify = ProcessInfo.processInfo.environment["PANE_NO_VERIFY"] == nil
    let start = Date()
    let result = try await RecordingScanner.scan(url: url, options: .init(), verify: verify)
    print("Scan found \(result.findings.count) items in "
          + "\(String(format: "%.1f", Date().timeIntervalSince(start)))s; checking the odd frames…")
    let leaks = try await LeakAudit.run(url: url, findings: result.findings, options: .init(), offset: 1,
                                        ranges: ranges).leaks
    for leak in leaks {
        print(String(format: "%.2fs  %@  %.0f%% covered  \"%@\"  at x=%.3f y=%.3f", leak.time, leak.kind.rawValue,
                     leak.covered * 100, leak.text, leak.rect.minX, leak.rect.minY))
    }
    print("\(leaks.count) uncovered sightings")

case "readable":
    // Sensitive text still readable in a finished video, such as an "(Edited)" export.
    guard args.count == 2 else { fail("usage: pane-tool readable <video>") }
    let leaks = try await LeakAudit.run(url: URL(fileURLWithPath: args[1]), findings: [], options: .init(), every: 1).leaks
    for leak in leaks {
        print(String(format: "%.2fs  %@  \"%@\"  at x=%.3f y=%.3f w=%.3f h=%.3f", leak.time, leak.kind.rawValue, leak.text,
                     leak.rect.minX, leak.rect.minY, leak.rect.width, leak.rect.height))
    }
    print("\(leaks.count) readable sightings")

case "readings":
    // What the scan read on each sampled frame, and the items it built from them.
    guard args.count == 4, let from = Double(args[2]), let to = Double(args[3]) else {
        fail("usage: pane-tool readings <video> <from> <to>")
    }
    let result = try await RecordingScanner.scan(url: URL(fileURLWithPath: args[1]), options: .init())
    for frame in result.frames where frame.time >= from && frame.time <= to {
        let found = frame.matches.map {
            String(format: "%@ \"%@\" x=%.3f y=%.3f w=%.3f h=%.3f", $0.kind.rawValue, $0.text,
                   $0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height)
        }
        print(formatTime(frame.time) + "  " + (found.isEmpty ? "-" : found.joined(separator: " | ")))
    }
    for finding in result.findings where finding.end >= from && finding.start <= to {
        print("item \(finding.kind.rawValue) \(formatTime(finding.start))–\(formatTime(finding.end)) "
              + "\(finding.samples.count) boxes \"\(finding.text)\"")
        if ProcessInfo.processInfo.environment["PANE_BOXES"] != nil {
            for sample in finding.samples where sample.time >= from && sample.time <= to {
                print(String(format: "  %.3fs x=%.3f y=%.3f w=%.3f h=%.3f", sample.time, sample.rect.minX,
                             sample.rect.minY, sample.rect.width, sample.rect.height))
            }
        }
    }

case "pointer-export":
    // What Pane does when a recording stops with Auto-blur off: pointer effects only.
    guard args.count == 3 else { fail("usage: pane-tool pointer-export <video> <out.mp4>") }
    let url = URL(fileURLWithPath: args[1])
    guard let track = PointerTrack.load(from: url) else { fail("No pointer recording in \(args[1])") }
    guard let videoTrack = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { fail("No video") }
    let size = try await videoTrack.load(.naturalSize)
    let start = Date()
    try await RedactionExporter.export(source: url, to: URL(fileURLWithPath: args[2]), findings: [],
                                       effects: [PointerRenderer(track: track, style: PointerEffectStyle(), videoSize: size)]
                                           .compactMap { $0 })
    print("Exported \(args[2]) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")

case "trim":
    // Export Video with a trim, without a scan: keeps from..to, with pointer effects.
    guard args.count == 5, let from = Double(args[3]), let to = Double(args[4]), from < to else {
        fail("usage: pane-tool trim <video> <out.mp4> <from> <to>")
    }
    let url = URL(fileURLWithPath: args[1])
    guard let videoTrack = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { fail("No video") }
    let size = try await videoTrack.load(.naturalSize)
    let track = PointerTrack.load(from: url)
    let start = Date()
    try await RedactionExporter.export(
        source: url, to: URL(fileURLWithPath: args[2]), findings: [],
        effects: [track.flatMap { PointerRenderer(track: $0, style: PointerEffectStyle(), videoSize: size) }].compactMap { $0 },
        timeRange: from...to)
    let output = AVURLAsset(url: URL(fileURLWithPath: args[2]))
    var lengths = ["file \(String(format: "%.3f", try await output.load(.duration).seconds))s"]
    for track in try await output.load(.tracks) {
        lengths.append("\(track.mediaType.rawValue) \(String(format: "%.3f", try await track.load(.timeRange).duration.seconds))s")
    }
    print("Kept \(formatTime(from))–\(formatTime(to)) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s: "
          + lengths.joined(separator: ", "))

case "finalcut":
    // What Send to Final Cut does: scan, then lay the files out for Final Cut.
    guard args.count == 3 || args.count == 4 else { fail("usage: pane-tool finalcut <video> <folder> [camera.mov]") }
    let url = URL(fileURLWithPath: args[1])
    let result = try await RecordingScanner.scan(url: url, options: .init())
    guard let videoTrack = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { fail("No video") }
    let size = try await videoTrack.load(.naturalSize)
    let track = PointerTrack.load(from: url)
    var captions: Captions?
    if #available(macOS 26, *) { captions = try? await CaptionTranscriber.transcribe(url: url) }
    let start = Date()
    let project = try await FinalCutHandoff.prepare(
        name: url.deletingPathExtension().lastPathComponent, screen: url,
        camera: args.count == 4 ? URL(fileURLWithPath: args[3]) : nil, findings: result.findings,
        effects: [track.flatMap { PointerRenderer(track: $0, style: PointerEffectStyle(), videoSize: size) }].compactMap { $0 },
        clicks: track?.clicks ?? [], in: URL(fileURLWithPath: args[2]), captions: captions)
    print("\(result.findings.count) blurs; wrote \(project.path) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")

case "zoom-export":
    try await ZoomTool.run(args)

case "follow":
    try await FollowTool.run(args)

case "retakes":
    // With out.mp4, also exports the video with the retakes cut (and pointer effects), as
    // Export Video does, with the cuts placed in the silence (--pause short|medium|long).
    let pause = args.firstIndex(of: "--pause").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        .flatMap(CutEdges.Pause.init(rawValue:)) ?? .medium
    let args = args.enumerated().filter { $0.element != "--pause" && ($0.offset == 0 || args[$0.offset - 1] != "--pause") }
        .map(\.element)
    guard args.count == 3 || args.count == 4 else {
        fail("usage: pane-tool retakes <video or audio> <script.txt> [out.mp4] [--pause short|medium|long]")
    }
    guard #available(macOS 26, *) else { fail("Needs macOS 26 or later") }
    let script = PrompterScript(try String(contentsOfFile: args[2], encoding: .utf8))
    let words = try await CaptionTranscriber.words(url: URL(fileURLWithPath: args[1]))
    let retakes = RetakeFinder.find(script: script, words: words)
    print("\(words.count) words heard, \(retakes.count) retake\(retakes.count == 1 ? "" : "s")")
    for retake in retakes {
        let cutWords = words.filter { $0.start >= retake.cut.lowerBound && $0.start < retake.cut.upperBound }
        print(String(format: "cut %.2f–%.2f s (%.2f s): \"%@\"", retake.cut.lowerBound, retake.cut.upperBound,
                     retake.cut.upperBound - retake.cut.lowerBound, cutWords.map(\.text).joined(separator: " ")))
        print("   said again: \(retake.text)…")
    }
    if args.count == 4 {
        let url = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[3])
        guard let videoTrack = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { fail("No video") }
        let size = try await videoTrack.load(.naturalSize)
        let effects: [any FrameEffect] = [PointerTrack.load(from: url).flatMap {
            PointerRenderer(track: $0, style: PointerEffectStyle(), videoSize: size)
        }].compactMap { $0 }
        let levels = try await AudioLevels.read(url: url)
        let cuts = CutEdges.placed(retakes.map(\.cut), levels: levels, words: words, pause: pause)
        print(String(format: "Speech is louder than %.0f dB. Cuts placed (%@ pause):", levels.speechThreshold, pause.rawValue))
        for cut in cuts { print(String(format: "   %.2f–%.2f s", cut.lowerBound, cut.upperBound)) }
        try await RedactionExporter.export(source: url, to: out, findings: [], effects: effects, cuts: cuts)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        let expected = VideoEdit(cuts: cuts).outputDuration(duration: duration)
        var lengths: [String] = []
        for track in try await AVURLAsset(url: out).load(.tracks) {
            lengths.append("\(track.mediaType.rawValue) \(String(format: "%.3f", try await track.load(.timeRange).duration.seconds))s")
        }
        print(String(format: "Exported: expected %.3fs; ", expected) + lengths.joined(separator: ", "))
    }

case "captions":
    // Captions from the narration, on device. The SRT goes to standard output; timing
    // goes to standard error. PANE_WORDS=1 also lists every word with its time. With an
    // output path, also writes a copy with the captions burned in.
    guard args.count == 2 || args.count == 3 else { fail("usage: pane-tool captions <video> [burned-in.mp4]") }
    guard #available(macOS 26, *) else { fail("Captions need macOS 26 or later") }
    let url = URL(fileURLWithPath: args[1])
    let audioSeconds = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first?.load(.timeRange).duration.seconds ?? 0
    if await CaptionTranscriber.needsDownload() { FileHandle.standardError.write(Data("Downloading the speech model…\n".utf8)) }
    let start = Date()
    let words = try await CaptionTranscriber.words(url: url)
    let seconds = Date().timeIntervalSince(start)
    if ProcessInfo.processInfo.environment["PANE_WORDS"] != nil {
        for word in words { FileHandle.standardError.write(Data(String(format: "%7.2f %7.2f  %@\n", word.start, word.end, word.text).utf8)) }
    }
    let captions = Captions(words: words, language: Locale.current.language.languageCode?.identifier ?? "en")
    print(captions.srt, terminator: "")
    FileHandle.standardError.write(Data(String(
        format: "%d words, %d captions from %.1f s of audio in %.1f s (%.1f s per minute of audio)\n",
        words.count, captions.cues.count, audioSeconds, seconds, seconds / max(audioSeconds / 60, 0.001)).utf8))
    if args.count == 3 {
        guard let videoTrack = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { fail("No video") }
        let size = try await videoTrack.load(.naturalSize)
        let renderer = CaptionRenderer(captions: captions, videoSize: size,
                                       cameraCircle: PointerTrack.load(from: url)?.cameraCircle)
        try await RedactionExporter.export(source: url, to: URL(fileURLWithPath: args[2]), findings: [],
                                           effects: [renderer].compactMap { $0 })
        FileHandle.standardError.write(Data("Wrote \(args[2])\n".utf8))
    }

case "pointer-frames":
    // For checking that the recorded pointer lines up with the real one in the video:
    // saves the frames where the pointer moved fastest, with a red cross where Pane
    // thinks it is, plus every click.
    guard args.count == 3 else { fail("usage: pane-tool pointer-frames <video> <folder>") }
    let url = URL(fileURLWithPath: args[1])
    guard let track = PointerTrack.load(from: url) else { fail("No pointer recording in \(args[1])") }
    let folder = URL(fileURLWithPath: args[2])
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    print("\(track.samples.count) samples, \(track.clicks.count) clicks, "
          + "\(track.samples.filter(\.isHand).count) samples with the pointing hand")
    for click in track.clicks {
        print(String(format: "click %@ at %.2fs (%.3f, %.3f)%@ held %.2fs", click.button.rawValue, click.time,
                     click.x, click.y, click.isHand ? " on a link" : "", click.duration))
    }
    let speeds = zip(track.samples, track.samples.dropFirst()).map { a, b in
        (time: b.time, speed: hypot(b.x - a.x, b.y - a.y) / max(b.time - a.time, 0.001))
    }
    var moments: [Double] = []
    for candidate in speeds.sorted(by: { $0.speed > $1.speed }) where moments.allSatisfy({ abs($0 - candidate.time) > 0.5 }) {
        moments.append(candidate.time)
        if moments.count == 6 { break }
    }
    moments += track.clicks.prefix(4).map(\.time)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    for (index, time) in moments.enumerated() {
        guard let (point, hand) = track.position(at: time) else { continue }
        let (image, actual) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        let rep = NSBitmapImageRep(cgImage: image)
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let tracked = track.position(at: actual.seconds)?.point ?? point
        let center = CGPoint(x: tracked.x * w, y: tracked.y * h)
        let crop = CGRect(x: center.x - 120, y: center.y - 120, width: 240, height: 240)
        let out = NSImage(size: NSSize(width: 480, height: 480))
        out.lockFocus()
        NSImage(cgImage: image, size: NSSize(width: w, height: h))
            .draw(in: NSRect(x: 0, y: 0, width: 480, height: 480), from: crop, operation: .copy, fraction: 1)
        NSColor.red.setFill()
        NSRect(x: 239, y: 220, width: 2, height: 40).fill()
        NSRect(x: 220, y: 239, width: 40, height: 2).fill()
        out.unlockFocus()
        // Velocity in video pixels per second, top-left origin (to match the image).
        let dt = 0.02
        if let a = track.position(at: actual.seconds - dt)?.point, let b = track.position(at: actual.seconds + dt)?.point {
            print(String(format: "%02d at %.3fs: moving (%.0f, %.0f) px/s", index, actual.seconds,
                         (b.x - a.x) * w / (2 * dt), -(b.y - a.y) * h / (2 * dt)))
        }
        let name = String(format: "%02d-%.2fs%@.png", index, actual.seconds, hand ? "-hand" : "")
        try NSBitmapImageRep(data: out.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            .write(to: folder.appendingPathComponent(name))
    }
    print("Wrote \(moments.count) frames to \(args[2])")

default:
    fail("usage: pane-tool sample|scan|export|frame|blur|check|pointer-demo|pointer-frames|audit|readings|readable|captions …")
}

/// A short 1280×720 video of a "document" with fake sensitive details that scrolls up,
/// to exercise detection and tracking.
enum SampleVideo {
    static let lines = [
        "Project notes for the onboarding call",
        "Contact: jane.doe@example.com",
        "Phone: (555) 123-4567",
        "OPENAI_API_KEY=sk-proj-A1b2C3d4E5f6G7h8I9j0K1l2",
        "Card on file 4242 4242 4242 4242",
        "Next steps: send the proposal on Friday",
    ]

    static let width = 1280, height = 720, fps = 30
    static let duration = 5.0

    /// How far the page has scrolled up, in pixels: a pause, a quick flick with easing,
    /// another pause, then a slow scroll that carries lines off the top and is still
    /// moving on the last frame.
    static func scroll(at t: Double) -> Double {
        func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
        switch t {
        case ..<0.8: return 0
        case ..<1.6: return 180 * ease((t - 0.8) / 0.8)
        case ..<2.4: return 180
        default: return 180 + 60 * (t - 2.4)
        }
    }

    static func lineY(_ index: Int, at t: Double) -> Double {
        600 - Double(index) * 80 + scroll(at: t)
    }

    static func write(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<Int(duration * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { fail("no pixel buffer") }
            draw(into: buffer, time: Double(frame) / Double(fps))
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ExportError.failed(nil) }
    }

    static func draw(into buffer: CVPixelBuffer, time: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black,
        ]
        for (index, line) in lines.enumerated() {
            let y = CGFloat(lineY(index, at: time))
            (line as NSString).draw(at: CGPoint(x: 80, y: y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A scripted pointer: moves, hovers a link with the pointing hand and clicks it, moves
/// on, right-clicks, then sits still long enough for the highlight to fade.
enum PointerDemo {
    static var track: PointerTrack {
        func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
        func position(at t: Double) -> (CGPoint, Bool) {
            let a = CGPoint(x: 0.25, y: 0.35), b = CGPoint(x: 0.55, y: 0.62), c = CGPoint(x: 0.3, y: 0.25)
            func mix(_ p: CGPoint, _ q: CGPoint, _ u: Double) -> CGPoint {
                CGPoint(x: p.x + (q.x - p.x) * ease(u), y: p.y + (q.y - p.y) * ease(u))
            }
            switch t {
            case ..<0.6: return (a, false)
            case ..<1.4: return (mix(a, b, (t - 0.6) / 0.8), false)
            case ..<2.4: return (b, t >= 1.5)
            case ..<3.2: return (mix(b, c, (t - 2.4) / 0.8), false)
            default: return (c, false)
            }
        }
        let samples = stride(from: 0.0, through: SampleVideo.duration, by: 1.0 / 60).map { t in
            let (p, hand) = position(at: t)
            return PointerTrack.Sample(time: t, x: p.x, y: p.y, isHand: hand)
        }
        let clicks = [
            PointerTrack.Click(time: 1.9, x: 0.55, y: 0.62, button: .left, isHand: true, duration: 0.1),
            PointerTrack.Click(time: 3.35, x: 0.3, y: 0.25, button: .right, isHand: false, duration: 0.1),
        ]
        return PointerTrack(samples: samples, clicks: clicks, pointSize: 1.0 / Double(SampleVideo.height), cameraCircle: nil)
    }
}
