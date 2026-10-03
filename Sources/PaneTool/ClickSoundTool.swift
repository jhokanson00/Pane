import AVFoundation
import PaneKit

/// Commands for checking click sounds in exports:
///
///   pane-tool click-demo <out.mp4> [--narration]   the sample with scripted clicks and click sounds
///   pane-tool click-export <video> <out.mp4>       pointer effects with click sounds, as Pane exports them
///   pane-tool click-finalcut <video> <folder>      Send to Final Cut with click sounds (no scan)
///   pane-tool click-check <source> <export>        where the clicks landed, and whether the rest is unchanged
enum ClickSoundTool {
    static func run(_ args: [String]) async throws {
        switch args.first {
        case "click-demo":
            guard args.count >= 2 else { fail("usage: pane-tool click-demo <out.mp4> [--narration]") }
            let folder = FileManager.default.temporaryDirectory
            var source = folder.appendingPathComponent("pane-click-demo.mp4")
            try await SampleVideo.write(to: source)
            if args.contains("--narration") {
                let narrated = folder.appendingPathComponent("pane-click-demo-narrated.mp4")
                try await addNarration(to: source, writing: narrated)
                source = narrated
            }
            // Saved with the source, so click-check finds the clicks the same way as for a recording.
            try PointerDemo.track.save(to: source)
            try await export(source, to: URL(fileURLWithPath: args[1]))
            print("Source: \(source.path)")

        case "click-export":
            guard args.count == 3 else { fail("usage: pane-tool click-export <video> <out.mp4>") }
            try await export(URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2]))

        case "click-finalcut":
            // Send to Final Cut with click sounds, without scanning for sensitive text.
            guard args.count == 3 else { fail("usage: pane-tool click-finalcut <video> <folder>") }
            let source = URL(fileURLWithPath: args[1])
            guard let track = PointerTrack.load(from: source) else { fail("No pointer recording in \(args[1])") }
            guard let video = try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first else { fail("No video") }
            var style = PointerEffectStyle()
            style.clickSounds = true
            let renderer = PointerRenderer(track: track, style: style, videoSize: try await video.load(.naturalSize))
            let project = try await FinalCutHandoff.prepare(
                name: source.deletingPathExtension().lastPathComponent, screen: source, camera: nil, findings: [],
                effects: [renderer].compactMap { $0 }, clicks: track.clicks,
                clickSounds: track.clickSounds(style: style), in: URL(fileURLWithPath: args[2]))
            print("Wrote \(project.path)")

        case "click-check":
            guard args.count == 3 else { fail("usage: pane-tool click-check <source> <export>") }
            try await check(source: URL(fileURLWithPath: args[1]), export: URL(fileURLWithPath: args[2]))

        default:
            fail("unknown command")
        }
    }

    /// Pointer effects in the default style with click sounds on.
    static func export(_ source: URL, to destination: URL) async throws {
        guard let track = PointerTrack.load(from: source) else { fail("No pointer recording in \(source.path)") }
        guard let video = try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first else { fail("No video") }
        var style = PointerEffectStyle()
        style.clickSounds = true
        let renderer = PointerRenderer(track: track, style: style, videoSize: try await video.load(.naturalSize))
        let clicks = track.clickSounds(style: style)
        let start = Date()
        try await RedactionExporter.export(source: source, to: destination, findings: [],
                                           effects: [renderer].compactMap { $0 }, clickSounds: clicks)
        print("Exported \(destination.path) with \(clicks.count) click sounds in "
              + String(format: "%.1f", Date().timeIntervalSince(start)) + "s")
    }

    // MARK: - Checking

    static let rate = Double(ClickSound.sampleRate)

    static func check(source: URL, export: URL) async throws {
        guard let track = PointerTrack.load(from: source) else { fail("No pointer recording in \(source.path)") }
        let clicks = track.clickSounds(style: { var s = PointerEffectStyle(); s.clickSounds = true; return s }())

        print("Durations (seconds):")
        for (label, url) in [("source", source), ("export", export)] {
            let asset = AVURLAsset(url: url)
            var line = "  \(label): file \(String(format: "%.4f", try await asset.load(.duration).seconds))"
            for item in try await asset.load(.tracks) {
                let range = try await item.load(.timeRange)
                var format = ""
                if let description = try await item.load(.formatDescriptions).first,
                   let audio = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    let codec = audio.mFormatID == kAudioFormatMPEG4AAC ? "AAC" : String(audio.mFormatID)
                    format = " \(codec) \(Int(audio.mSampleRate)) Hz \(audio.mChannelsPerFrame) ch "
                        + "\(Int(try await item.load(.estimatedDataRate) / 1000)) kb/s"
                }
                line += String(format: ", %@ %.4f–%.4f%@", item.mediaType.rawValue, range.start.seconds,
                               range.end.seconds, format)
            }
            print(line)
        }

        let original = try await decodeFirstAudio(source)
        guard let exported = try await decodeFirstAudio(export) else { fail("The export has no audio") }
        let length = exported.count
        print("Decoded first audio track: source \(original.map { "\($0.count)" } ?? "none"), export \(length) samples")
        let before = original.map { Array($0.prefix(length)) + [Float](repeating: 0, count: max(0, length - $0.count)) }
            ?? [Float](repeating: 0, count: length)

        // Sync: the export's audio should line up with the source's to the sample.
        if original != nil {
            let lag = bestLag(before, exported, avoiding: clicks)
            print("Sync: export audio is \(lag) samples (\(String(format: "%.2f", Double(lag) / rate * 1000)) ms) "
                  + "from the source's")
        }

        // What the export added: the clicks, plus the re-encoding's tiny differences.
        let added = zip(exported, before).map { $0 - $1 }
        print("Clicks (\(clicks.count)):")
        var worst = 0.0
        for click in clicks {
            let center = Int((click.time * rate).rounded())
            let window = max(0, center - Int(0.03 * rate))..<min(length, center + Int(0.03 * rate))
            guard !window.isEmpty else { print("  \(click.time)s: past the end of the audio"); continue }
            let peak = window.map { abs(added[$0]) }.max() ?? 0
            let onset = window.first { abs(added[$0]) >= peak * 0.2 } ?? center
            let error = Double(onset - center) / rate * 1000
            worst = max(worst, abs(error))
            print(String(format: "  %@ at %.3fs: heard at %.3fs (%+.2f ms), peak %.1f dBFS", click.button.rawValue,
                         click.time, Double(onset) / rate, error, 20 * log10(max(Double(peak), 1e-9))))
        }
        print(String(format: "Worst click timing: %.2f ms", worst))

        // Elsewhere: the narration's level in 50 ms windows away from the clicks.
        let step = Int(0.05 * rate)
        let near = clicks.map { Int(($0.time - 0.01) * rate)..<Int(($0.time + 0.08) * rate) }
        var differences: [Double] = []
        var residual = 0.0, signal = 0.0, loudestAdded: Float = 0
        for start in stride(from: 0, to: length - step, by: step) {
            let range = start..<(start + step)
            guard !near.contains(where: { $0.overlaps(range) }) else { continue }
            let a = rms(before[range]), b = rms(exported[range])
            residual += Double(range.reduce(Float(0)) { $0 + added[$1] * added[$1] })
            signal += Double(range.reduce(Float(0)) { $0 + before[$1] * before[$1] })
            loudestAdded = max(loudestAdded, range.map { abs(added[$0]) }.max() ?? 0)
            if a > 0.003 { differences.append(abs(20 * log10(b / a))) }
        }
        if original == nil {
            print(String(format: "Away from clicks: loudest sample %.1f dBFS (silence expected)",
                         20 * log10(max(Double(loudestAdded), 1e-9))))
        } else {
            let mean = differences.reduce(0, +) / Double(max(differences.count, 1))
            print(String(format: "Away from clicks: level differs by %.3f dB on average, %.3f dB at most, over %d "
                         + "windows with sound; re-encoding difference %.1f dB below the narration "
                         + "(narration peaks at %.1f dBFS)",
                         mean, differences.max() ?? 0, differences.count,
                         10 * log10(max(signal, 1e-12) / max(residual, 1e-12)),
                         20 * log10(max(Double(before.map(abs).max() ?? 0), 1e-9))))
        }
    }

    /// The first audio track as mono 48 kHz samples, each at its place on the timeline.
    static func decodeFirstAudio(_ url: URL) async throws -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard frames > 0, let block = buffer.dataBuffer else { continue }
            let start = Int((buffer.presentationTimeStamp.seconds * rate).rounded())
            if samples.count < start + frames { samples += [Float](repeating: 0, count: start + frames - samples.count) }
            var chunk = [Float](repeating: 0, count: frames)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            samples.replaceSubrange(start..<(start + frames), with: chunk)
        }
        return samples
    }

    /// The shift (in samples) that best lines `b` up with `a`, from their loudest second
    /// away from the clicks.
    static func bestLag(_ a: [Float], _ b: [Float], avoiding clicks: [PointerTrack.Click]) -> Int {
        let span = Int(rate)
        var best = (start: 0, energy: -1.0)
        for start in stride(from: 2048, to: max(2048, min(a.count, b.count) - span - 2048), by: span / 4) {
            let range = start..<(start + span)
            if clicks.contains(where: { range.contains(Int($0.time * rate)) }) { continue }
            let energy = rms(a[range])
            if energy > best.energy { best = (start, energy) }
        }
        var lag = 0
        var top = -Float.infinity
        for shift in -2048...2048 {
            var sum: Float = 0
            for i in stride(from: best.start, to: best.start + span, by: 1) where i + shift >= 0 && i + shift < b.count {
                sum += a[i] * b[i + shift]
            }
            if sum > top { top = sum; lag = shift }
        }
        return lag
    }

    static func rms(_ values: ArraySlice<Float>) -> Double {
        guard !values.isEmpty else { return 0 }
        return sqrt(Double(values.reduce(Float(0)) { $0 + $1 * $1 }) / Double(values.count))
    }

    // MARK: - Synthetic narration

    /// The sample with a stereo voice-like track: a buzzy 120–180 Hz tone in syllables,
    /// with pauses, so there's narration both around and under the clicks.
    static func addNarration(to video: URL, writing destination: URL) async throws {
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("pane-click-narration.m4a")
        try? FileManager.default.removeItem(at: audioURL)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: audioURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        let frames = Int(SampleVideo.duration * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        var phase = 0.0
        for i in 0..<frames {
            let t = Double(i) / rate
            let pitch = 150 + 30 * sin(2 * .pi * 0.7 * t)
            phase += 2 * .pi * pitch / rate
            let voice = (1...8).reduce(0.0) { $0 + sin(phase * Double($1)) / Double($1) }
            let syllables = max(0, sin(2 * .pi * 4 * t)) * (t.truncatingRemainder(dividingBy: 2.2) < 1.6 ? 1 : 0)
            let value = Float(voice * syllables * 0.12)
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value * 0.8
        }
        try file.write(from: buffer)
        file.close()

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audioURL)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first!
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first!
        let range = CMTimeRange(start: .zero, duration: try await videoAsset.load(.duration))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: min(range.duration, try await audioTrack.load(.timeRange).duration)),
                             of: audioTrack, at: .zero)
        try? FileManager.default.removeItem(at: destination)
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: destination, as: .mp4)
    }
}
