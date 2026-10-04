import AVFoundation
import CoreImage
import XCTest
@testable import PaneKit

final class TrimTests: XCTestCase {
    // MARK: - Setting the range

    func testSettingStartAndEnd() {
        XCTAssertEqual(Trim.start(at: 3, keeping: nil, duration: 72), 3...72)
        XCTAssertEqual(Trim.end(at: 60, keeping: 3...72, duration: 72), 3...60)
        // Back to the very start and end keeps the whole video: no trim.
        XCTAssertNil(Trim.start(at: 0, keeping: nil, duration: 72))
        XCTAssertNil(Trim.end(at: 72, keeping: 0...72, duration: 72))
        // A start past the end gives the end back, and an end before the start gives
        // the start back.
        XCTAssertEqual(Trim.start(at: 65, keeping: 3...60, duration: 72), 65...72)
        XCTAssertEqual(Trim.end(at: 2, keeping: 3...60, duration: 72), 0...2)
        // Never shorter than the minimum.
        XCTAssertEqual(Trim.start(at: 72, keeping: nil, duration: 72), 71.5...72)
        XCTAssertEqual(Trim.end(at: 0, keeping: nil, duration: 72), 0...0.5)
    }

    func testFramesRoundToTheNearestFrame() {
        XCTAssertEqual(Trim.frames(3.01...12.49, frameRate: 30, totalFrames: 900), 90..<375)
        // Kept inside the file, and at least one frame long.
        XCTAssertEqual(Trim.frames(29.99...40, frameRate: 30, totalFrames: 900), 899..<900)
    }

    // MARK: - Export

    /// A 2.5 s, 30 fps video whose frame n is gray level 20 + 3n, with silence except for
    /// a 1 kHz beep from 2.0 to 2.2 s.
    private func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pane-trim-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        writer.add(video)
        writer.add(audio)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var format: CMAudioFormatDescription?
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

        // Fed to whichever input is ready, since the writer holds one back until the
        // other catches up.
        var frame = 0, chunk = 0
        while frame < 75 || chunk < 75 {
            var appended = false
            if frame < 75, video.isReadyForMoreMediaData {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
                CVPixelBufferLockBaseAddress(buffer!, [])
                memset(CVPixelBufferGetBaseAddress(buffer!), Int32(20 + 3 * frame), CVPixelBufferGetDataSize(buffer!))
                CVPixelBufferUnlockBaseAddress(buffer!, [])
                adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
                frame += 1
                if frame == 75 { video.markAsFinished() }
                appended = true
            }
            if chunk < 75, audio.isReadyForMoreMediaData {
                let first = chunk * 1600
                let samples = (first..<first + 1600).map { n -> Float in
                    let t = Double(n) / 48_000
                    return t >= 2 && t < 2.2 ? Float(0.5 * sin(2 * .pi * 1000 * t)) : 0
                }
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: samples.count * 4,
                                                   blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                   dataLength: samples.count * 4, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                   blockBufferOut: &block)
                samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                                                                            offsetIntoDestination: 0, dataLength: $0.count) }
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                                presentationTimeStamp: CMTime(value: CMTimeValue(first), timescale: 48_000),
                                                decodeTimeStamp: .invalid)
                var size = 4
                var sample: CMSampleBuffer?
                CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                                     refcon: nil, formatDescription: format, sampleCount: samples.count,
                                     sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                     sampleSizeArray: &size, sampleBufferOut: &sample)
                audio.append(sample!)
                chunk += 1
                if chunk == 75 { audio.markAsFinished() }
                appended = true
            }
            if writer.status == .failed { throw writer.error ?? ExportError.failed(nil) }
            if !appended { try await Task.sleep(for: .milliseconds(2)) }
        }
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }

    private func gray(_ url: URL, at seconds: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        var rgba = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: image), toBitmap: &rgba, rowBytes: 4,
                           bounds: CGRect(x: 160, y: 90, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return Int(rgba[0])
    }

    /// When the beep starts, and how long the decoded sound lasts, in seconds.
    private func audio(_ url: URL) async throws -> (beep: Double?, length: Double) {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var beep: Double?
        var end = 0.0
        while let sample = output.copyNextSampleBuffer() {
            let count = sample.numSamples
            let start = sample.presentationTimeStamp.seconds
            end = max(end, start + Double(count) / 48_000)
            guard beep == nil, let data = try? sample.dataBuffer?.dataBytes() else { continue }
            data.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Float.self)
                if let index = values.firstIndex(where: { abs($0) > 0.1 }) {
                    beep = start + Double(index) / 48_000
                }
            }
        }
        return (beep, end)
    }

    /// Turns the whole frame red from 2.0 s of the source on.
    private struct RedFromTwoSeconds: FrameEffect {
        func isActive(at time: Double) -> Bool { time >= 2 }
        func apply(to frame: CIImage, at time: Double) -> CIImage {
            CIImage(color: .red).cropped(to: frame.extent)
        }
    }

    func testExportKeepsOnlyTheRangeInStep() async throws {
        let source = try await makeVideo()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("pane-trim-out-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        let original = try await audio(source)
        XCTAssertEqual(original.beep ?? 0, 2.0, accuracy: 0.005)

        // Mid-frame and mid-packet on purpose: frame 30 runs from 1.0 to 1.033 s.
        try await RedactionExporter.export(source: source, to: output, findings: [], effects: [RedFromTwoSeconds()],
                                           timeRange: 1.01...2.4)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.39, accuracy: 0.001)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first!
        let videoRange = try await videoTrack.load(.timeRange)
        XCTAssertEqual(videoRange.duration.seconds, 1.39, accuracy: 0.001)
        XCTAssertEqual(videoRange.start.seconds, 0, accuracy: 0.001)

        // The first frame is source frame 30, the one showing at 1.01 s, not its
        // neighbors. Gray levels are compared with the source's own decoded frames.
        let first = try await gray(output, at: 0)
        let sourceGrays = try await [29, 30, 31].asyncMap { try await self.gray(source, at: Double($0) / 30 + 0.001) }
        XCTAssertEqual(first, sourceGrays[1], accuracy: 1)
        XCTAssertGreaterThan(abs(first - sourceGrays[0]), 1)
        XCTAssertGreaterThan(abs(first - sourceGrays[2]), 1)
        // 0.97 s in is source 1.98 s, frame 59, just before the effect starts.
        let beforeEffect = try await gray(output, at: 0.97)
        let sourceBefore = try await gray(source, at: 59.0 / 30 + 0.001)
        XCTAssertEqual(beforeEffect, sourceBefore, accuracy: 1)
        // Red from the effect: it's placed by source time (2.0 s), now 0.99 s in.
        let afterEffect = try await gray(output, at: 1.0)
        XCTAssertGreaterThan(afterEffect, 240)

        // The beep moved from 2.0 s to 0.99 s, and the sound lasts as long as the video.
        let trimmed = try await audio(output)
        XCTAssertEqual(trimmed.beep ?? 0, 0.99, accuracy: 0.002)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first!
        let audioRange = try await audioTrack.load(.timeRange)
        XCTAssertEqual(audioRange.duration.seconds, 1.39, accuracy: 0.001)
        XCTAssertEqual(trimmed.length, 1.39, accuracy: 0.001)
        print("Trimmed export: duration \(duration) s, video \(videoRange.duration.seconds) s, first frame gray \(first) "
              + "(source frames 29/30/31: \(sourceGrays)), at 0.97 s gray \(beforeEffect) (source \(sourceBefore)), "
              + "at 1.0 s red \(afterEffect), audio track \(audioRange.duration.seconds) s, "
              + "beep at \(trimmed.beep ?? -1) s (was \(original.beep ?? -1) s), decoded sound \(trimmed.length) s")
    }

    /// A cut from the middle (as for a retake): left out of picture and sound, the rest
    /// closed up, blurs and effects still placed by source time.
    func testExportLeavesOutACutFromTheMiddle() async throws {
        let source = try await makeVideo()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("pane-cut-out-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try await RedactionExporter.export(source: source, to: output, findings: [], effects: [RedFromTwoSeconds()],
                                           cuts: [0.5...1.5])

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.5, accuracy: 0.002)
        // Before the cut, unchanged: 0.4 s is source frame 12.
        let early = try await gray(output, at: 0.4)
        let sourceEarly = try await gray(source, at: 12.0 / 30 + 0.001)
        XCTAssertEqual(early, sourceEarly, accuracy: 1)
        // After it, a second earlier: 0.7 s in is source 1.7 s, frame 51.
        let late = try await gray(output, at: 0.7)
        let sourceLate = try await gray(source, at: 51.0 / 30 + 0.001)
        XCTAssertEqual(late, sourceLate, accuracy: 1)
        // The effect starts at source 2.0 s, now 1.0 s in.
        let red = try await gray(output, at: 1.05)
        XCTAssertGreaterThan(red, 240)
        let beforeRed = try await gray(output, at: 0.95)
        XCTAssertLessThan(beforeRed, 240)

        // The beep moved from 2.0 s to 1.0 s, and the sound is as long as the picture.
        let sound = try await audio(output)
        XCTAssertEqual(sound.beep ?? 0, 1.0, accuracy: 0.002)
        XCTAssertEqual(sound.length, 1.5, accuracy: 0.002)
    }

    /// A trim and a cut together.
    func testExportTrimAndCut() async throws {
        let source = try await makeVideo()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("pane-cut-out-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try await RedactionExporter.export(source: source, to: output, findings: [],
                                           timeRange: 0.2...2.4, cuts: [1.0...1.6])
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 1.6, accuracy: 0.002)
        // The beep at source 2.0 s: 0.2 s trimmed and 0.6 s cut before it.
        let sound = try await audio(output)
        XCTAssertEqual(sound.beep ?? 0, 1.2, accuracy: 0.002)
        XCTAssertEqual(sound.length, 1.6, accuracy: 0.002)
    }

    func testExportWithoutRangeKeepsEverything() async throws {
        let source = try await makeVideo()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("pane-trim-out-\(UUID()).mp4")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try await RedactionExporter.export(source: source, to: output, findings: [])
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 2.5, accuracy: 0.05)
        let first = try await gray(output, at: 0)
        let sourceFirst = try await gray(source, at: 0)
        XCTAssertEqual(first, sourceFirst, accuracy: 1)
        let beep = try await audio(output).beep
        XCTAssertEqual(beep ?? 0, 2.0, accuracy: 0.005)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
