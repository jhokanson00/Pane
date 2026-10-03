import AVFoundation
import XCTest
@testable import PaneKit

final class ClickSoundTests: XCTestCase {
    private let rate = Double(ClickSound.sampleRate)

    // MARK: - The sound

    func testClickIsShortSoftAndStartsOnItsAttack() {
        for button in [PointerTrack.Button.left, .right] {
            let sound = ClickSound.samples(for: button)
            XCTAssertEqual(sound.count, 2880, "60 ms at 48 kHz")
            let loudest = sound.indices.max { abs(sound[$0]) < abs(sound[$1]) }!
            XCTAssertLessThan(loudest, 48, "peaks within the first millisecond")
            XCTAssertLessThanOrEqual(sound.map(abs).max()!, 0.156, "about 16 dB below full scale")
            // Fades well below hearing by the end, and ends on silence.
            XCTAssertLessThan(sound[1920...].map(abs).max()!, 0.01)
            XCTAssertEqual(sound.last, 0)
            // Clicky, not a thump: nearly all of it is over within 5 ms.
            let total = sound.reduce(0) { $0 + $1 * $1 }
            XCTAssertGreaterThan(sound[..<240].reduce(0) { $0 + $1 * $1 }, total * 0.9)
        }
        XCTAssertNotEqual(ClickSound.samples(for: .left), ClickSound.samples(for: .right))
        XCTAssertEqual(ClickSound.samples(for: .other), ClickSound.samples(for: .left))
    }

    func testWavFile() {
        let wav = ClickSound.wav(for: .left)
        XCTAssertEqual(wav.count, 44 + 2880 * 2)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        func uint32(_ at: Int) -> UInt32 { wav[at..<(at + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        XCTAssertEqual(uint32(24), 48_000)
        XCTAssertEqual(uint32(40), 2880 * 2)
    }

    // MARK: - Which clicks

    func testOnlyEnabledClicksOnTheVideoSoundWhenTurnedOn() {
        var track = PointerTrack(samples: [], clicks: [
            .init(time: 3, x: 0.5, y: 0.5, button: .right, isHand: false, duration: 0.1),
            .init(time: 1, x: 0.5, y: 0.5, button: .left, isHand: true, duration: 0.1),
            .init(time: 2, x: 1.4, y: 0.5, button: .left, isHand: false, duration: 0.1),
            .init(time: 4, x: 0.2, y: 0.2, button: .left, isHand: false, duration: 0.1),
        ], pointSize: 1.0 / 900, cameraCircle: nil)
        track.clicks[3].isEnabled = false
        var style = PointerEffectStyle()
        XCTAssertEqual(track.clickSounds(style: style), [], "off by default")
        style.clickSounds = true
        XCTAssertEqual(track.clickSounds(style: style).map(\.time), [1, 3])
    }

    func testStyleSavedBeforeClickSoundsLoadsWithThemOff() throws {
        let old = #"{"highlight":true,"fadeWhenStill":true,"clicks":true,"tint":"blue","size":"large"}"#
        let style = try JSONDecoder().decode(PointerEffectStyle.self, from: Data(old.utf8))
        XCTAssertFalse(style.clickSounds)
        XCTAssertEqual(style.tint, .blue)

        var on = PointerEffectStyle()
        on.clickSounds = true
        XCTAssertEqual(try JSONDecoder().decode(PointerEffectStyle.self, from: JSONEncoder().encode(on)), on)
    }

    // MARK: - Mixing

    private let clicks = [
        PointerTrack.Click(time: 0.5, x: 0.5, y: 0.5, button: .left, isHand: false, duration: 0.1),
        PointerTrack.Click(time: 0.52, x: 0.5, y: 0.5, button: .right, isHand: false, duration: 0.1),
    ]

    func testMixLandsOnTheExactSampleAcrossBufferBoundaries() {
        let mixer = ClickSoundMixer(clicks: clicks)
        let frames = Int(rate), channels = 2
        // Narration everywhere: a quiet ramp, different in each channel.
        let narration = (0..<frames * channels).map { Float($0 % 977) / 977 * 0.1 * ($0 % 2 == 0 ? 1 : -1) }

        var whole = narration
        whole.withUnsafeMutableBufferPointer { mixer.mix(into: $0, channels: channels, start: 0) }

        // The same audio in odd-sized pieces, one of them splitting the first click.
        var pieces = narration
        var start = 0
        for size in [24_011, 7, 1023, 4096, 48_000] where start < frames {
            let count = min(size, frames - start)
            pieces.withUnsafeMutableBufferPointer { buffer in
                let slice = UnsafeMutableBufferPointer(rebasing: buffer[(start * channels)..<((start + count) * channels)])
                mixer.mix(into: slice, channels: channels, start: start)
            }
            start += count
        }
        XCTAssertEqual(whole, pieces)

        let first = 24_000, second = 24_960
        XCTAssertEqual(whole[..<(first * channels)], narration[..<(first * channels)], "untouched before the click")
        // The sound starts on its sample, in both channels.
        let left = ClickSound.samples(for: .left), right = ClickSound.samples(for: .right)
        for position in first..<(first + 200) {
            for channel in 0..<channels {
                let index = position * channels + channel
                XCTAssertEqual(whole[index] - narration[index], left[position - first], accuracy: 1e-6)
            }
        }
        let end = second + 2880
        XCTAssertEqual(whole[(end * channels)...], narration[(end * channels)...], "untouched after the last click")
        // The overlapping right-click is added on top of the left one.
        let index = second + 10
        XCTAssertEqual(whole[index * channels] - narration[index * channels],
                       left[index - first] + right[10], accuracy: 1e-6)
    }

    func testLoudMomentsAreRoundedOffNotClipped() {
        let mixer = ClickSoundMixer(clicks: [clicks[0]])
        var loud = [Float](repeating: 0.95, count: Int(rate))
        loud.withUnsafeMutableBufferPointer { mixer.mix(into: $0, channels: 1, start: 0) }
        XCTAssertLessThan(loud.map(abs).max()!, 1)
        XCTAssertEqual(ClickSoundMixer.limit(0.5), 0.5)
        XCTAssertEqual(ClickSoundMixer.limit(-0.9), -0.9)
        XCTAssertEqual(ClickSoundMixer.limit(-3), -1, accuracy: 0.0001)
    }

    // MARK: - Export

    func testRecordingWithoutAudioGetsATrackWithJustTheClicks() async throws {
        let source = try await Self.writeVideo(seconds: 1)
        let output = Self.temporaryURL("mp4")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }

        try await RedactionExporter.export(source: source, to: output, findings: [], clickSounds: [clicks[0]])

        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video).first!
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let videoLength = try await video.load(.timeRange).duration.seconds
        let audioLength = try await audio.load(.timeRange).duration.seconds
        let fileLength = try await asset.load(.duration).seconds
        XCTAssertEqual(videoLength, 1, accuracy: 0.0001)
        XCTAssertEqual(audioLength, 1, accuracy: 0.0001)
        XCTAssertEqual(fileLength, 1, accuracy: 0.0001)

        let samples = try await Self.decode(output)
        XCTAssertEqual(samples.count, Int(rate))
        let onset = try XCTUnwrap(samples.firstIndex { abs($0) > 0.03 })
        XCTAssertEqual(Double(onset - 24_000) / rate, 0, accuracy: 0.001, "within a millisecond of the click")
        XCTAssertEqual(samples[..<22_900].map(abs).max()!, 0, accuracy: 0.0001, "silent before")
        // AAC smears a faint pre-echo up to one 1024-sample block ahead; it stays inaudible.
        XCTAssertLessThan(samples[22_900..<23_990].map(abs).max()!, 0.01)
        XCTAssertEqual(samples[27_000...].map(abs).max()!, 0, accuracy: 0.0001, "silent after")
    }

    func testClicksAreMixedIntoTheFirstTrackInSync() async throws {
        let source = try await Self.writeVideo(seconds: 1, narration: true)
        let plain = Self.temporaryURL("mp4"), clicked = Self.temporaryURL("mp4")
        defer { [source, plain, clicked].forEach { try? FileManager.default.removeItem(at: $0) } }

        try await RedactionExporter.export(source: source, to: plain, findings: [])
        try await RedactionExporter.export(source: source, to: clicked, findings: [], clickSounds: [clicks[0]])

        let audio = try await AVURLAsset(url: clicked).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let format = try await audio[0].load(.formatDescriptions).first!
        let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
        XCTAssertEqual(description.mChannelsPerFrame, 2, "keeps the channels")
        XCTAssertEqual(description.mSampleRate, 48_000)
        XCTAssertEqual(description.mFormatID, kAudioFormatMPEG4AAC)

        let before = try await Self.decode(plain), after = try await Self.decode(clicked)
        XCTAssertEqual(after.count, before.count, "same length, to the sample")

        // Away from the click the narration is the same, to within re-encoding: a shift of
        // even one sample would leave a difference about 25 dB below the tone.
        let away = Array(2_400..<23_000) + Array(28_000..<(before.count - 2_400))
        let difference = away.reduce(0.0) { $0 + Double(pow(after[$1] - before[$1], 2)) }
        let signal = away.reduce(0.0) { $0 + Double(pow(before[$1], 2)) }
        XCTAssertLessThan(10 * log10(difference / signal), -30)

        let added = zip(after, before).map { $0 - $1 }
        let peak = added[23_000..<27_000].map(abs).max()!
        XCTAssertGreaterThan(peak, 0.1)
        let onset = added.firstIndex { abs($0) >= peak * 0.2 }!
        XCTAssertEqual(Double(onset - 24_000) / rate, 0, accuracy: 0.001, "within a millisecond of the click")
    }

    /// Trimmed to 0.25–0.85 s: the click at 0.5 s is heard 0.25 s into the copy, and the
    /// narration stays as in a trimmed copy without clicks.
    func testTrimmedExportShiftsTheClicksWithTheNarration() async throws {
        let source = try await Self.writeVideo(seconds: 1, narration: true)
        let plain = Self.temporaryURL("mp4"), clicked = Self.temporaryURL("mp4")
        defer { [source, plain, clicked].forEach { try? FileManager.default.removeItem(at: $0) } }

        try await RedactionExporter.export(source: source, to: plain, findings: [], timeRange: 0.25...0.85)
        try await RedactionExporter.export(source: source, to: clicked, findings: [], clickSounds: [clicks[0]],
                                           timeRange: 0.25...0.85)

        let fileLength = try await AVURLAsset(url: clicked).load(.duration).seconds
        XCTAssertEqual(fileLength, 0.6, accuracy: 0.001)
        let before = try await Self.decode(plain), after = try await Self.decode(clicked)
        XCTAssertEqual(Double(after.count), 0.6 * rate, accuracy: 1)
        XCTAssertEqual(after.count, before.count, "same length, to the sample")

        let away = Array(2_400..<11_000) + Array(16_000..<(before.count - 2_400))
        let difference = away.reduce(0.0) { $0 + Double(pow(after[$1] - before[$1], 2)) }
        let signal = away.reduce(0.0) { $0 + Double(pow(before[$1], 2)) }
        XCTAssertLessThan(10 * log10(difference / signal), -30, "narration in step")

        let added = zip(after, before).map { $0 - $1 }
        let peak = added[11_000..<15_000].map(abs).max()!
        XCTAssertGreaterThan(peak, 0.1)
        let onset = added.firstIndex { abs($0) >= peak * 0.2 }!
        XCTAssertEqual(Double(onset - 12_000) / rate, 0, accuracy: 0.001, "within a millisecond of the click")
    }

    func testTrimmedRecordingWithoutAudioGetsJustTheKeptClicks() async throws {
        let source = try await Self.writeVideo(seconds: 1)
        let output = Self.temporaryURL("mp4")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }

        try await RedactionExporter.export(source: source, to: output, findings: [], clickSounds: [clicks[0]],
                                           timeRange: 0.25...0.85)

        let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        let audioLength = try await XCTUnwrap(audio.first).load(.timeRange).duration.seconds
        XCTAssertEqual(audioLength, 0.6, accuracy: 0.001)
        let samples = try await Self.decode(output)
        let onset = try XCTUnwrap(samples.firstIndex { abs($0) > 0.03 })
        XCTAssertEqual(Double(onset - 12_000) / rate, 0, accuracy: 0.001, "within a millisecond of the click")
    }

    // MARK: - Helpers

    private static func temporaryURL(_ type: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pane-click-\(UUID()).\(type)")
    }

    /// A small gray video, with a stereo 440 Hz tone for narration if asked.
    private static func writeVideo(seconds: Double, narration: Bool = false) async throws -> URL {
        let url = temporaryURL("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), 128, CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard narration else { return url }

        let tone = temporaryURL("m4a")
        do {
            let file = try AVAudioFile(forWriting: tone, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            let frames = AVAudioFrameCount(seconds * 48_000)
            let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!,
                                          frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                let value = Float(sin(2 * .pi * 440 * Double(i) / 48_000) * 0.1)
                buffer.floatChannelData![0][i] = value
                buffer.floatChannelData![1][i] = value
            }
            try file.write(from: buffer)
            file.close()
        }
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0], at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: try await AVURLAsset(url: tone).loadTracks(withMediaType: .audio)[0], at: .zero)
        let combined = temporaryURL("mp4")
        try await AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
            .export(to: combined, as: .mp4)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: tone)
        return combined
    }

    /// The first audio track as mono 48 kHz samples, each at its place on the timeline.
    private static func decode(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard frames > 0, let block = buffer.dataBuffer else { continue }
            let start = ClickSoundAudio.samplePosition(buffer.presentationTimeStamp)
            if samples.count < start + frames { samples += [Float](repeating: 0, count: start + frames - samples.count) }
            var chunk = [Float](repeating: 0, count: frames)
            chunk.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            samples.replaceSubrange(start..<(start + frames), with: chunk)
        }
        return samples
    }
}
