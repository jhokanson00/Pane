import AVFoundation
import XCTest
@testable import PaneKit

final class RecordingPausesTests: XCTestCase {
    /// Recording from 100 s on the host clock, paused 102–103 s and 105–107.5 s.
    var twoPauses: RecordingPauses {
        var pauses = RecordingPauses()
        pauses.pause(at: 102)
        pauses.resume(at: 103)
        pauses.pause(at: 105)
        pauses.resume(at: 107.5)
        return pauses
    }

    func testNeverPausedChangesNothing() {
        let pauses = RecordingPauses()
        XCTAssertFalse(pauses.isPaused)
        XCTAssertEqual(pauses.recordedTime(at: 123.456), 123.456)
        let time = CMTime(value: 123_456_789_012, timescale: 1_000_000_000)
        XCTAssertEqual(pauses.recordedTime(at: time), time, "exactly the same timestamp")
        XCTAssertEqual(pauses.pieces(start: 10, count: 1024, rate: 48_000),
                       [.init(first: 0, count: 1024, time: 10)])
    }

    func testSeveralPausesShiftLaterTimesBack() {
        let pauses = twoPauses
        XCTAssertEqual(pauses.recordedTime(at: 101), 101)
        XCTAssertEqual(pauses.recordedTime(at: 104), 103, "after one 1 s pause")
        XCTAssertEqual(pauses.recordedTime(at: 110), 106.5, "after 3.5 s of pauses")
        XCTAssertEqual(pauses.recordedDuration(from: 100, to: 110), 6.5)

        // Inside a pause, time stands still where the pause began.
        XCTAssertEqual(pauses.recordedTime(at: 102.5), 102)
        XCTAssertEqual(pauses.recordedTime(at: 106), 104)
        XCTAssertEqual(pauses.recordedDuration(from: 100, to: 106), 4)

        // A pause covers its start but not its end.
        XCTAssertTrue(pauses.isPaused(at: 102))
        XCTAssertTrue(pauses.isPaused(at: 102.999))
        XCTAssertFalse(pauses.isPaused(at: 103))
        XCTAssertFalse(pauses.isPaused(at: 101.999))
        XCTAssertTrue(pauses.isPaused(at: 107))
        XCTAssertFalse(pauses.isPaused(at: 108))

        let host = CMTime(value: 110_000_000_000, timescale: 1_000_000_000)
        XCTAssertEqual(pauses.recordedTime(at: host).seconds, 106.5, accuracy: 1e-9)
    }

    func testVideoFramesStayInOrderWithNoGap() {
        // A frame every 1/30 s from 100 to 110 s, dropping paused ones.
        let pauses = twoPauses
        var times: [Double] = []
        for frame in 0..<300 {
            let host = 100 + Double(frame) / 30
            guard !pauses.isPaused(at: host) else { continue }
            times.append(pauses.recordedTime(at: host))
        }
        XCTAssertEqual(times.count, 300 - 30 - 75)
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThan(b, a)
            XCTAssertLessThanOrEqual(b - a, 1.0 / 30 + 1e-9, "no gap where a pause was cut")
        }
        XCTAssertEqual(times.last! - times.first!, 6.5 - 1.0 / 30, accuracy: 1e-9)
    }

    func testStopWhilePaused() {
        var pauses = RecordingPauses()
        pauses.pause(at: 102)
        pauses.resume(at: 103)
        pauses.pause(at: 105)
        XCTAssertTrue(pauses.isPaused)
        // Stopped at 109 while still paused: the file ends where the pause began.
        XCTAssertEqual(pauses.recordedTime(at: 109), 104)
        XCTAssertEqual(pauses.recordedDuration(from: 100, to: 109), 4)
        XCTAssertTrue(pauses.isPaused(at: 1_000))
        // Audio captured before the pause but arriving late is still kept.
        XCTAssertEqual(pauses.pieces(start: 104.99, count: 960, rate: 48_000).map(\.count), [480])
    }

    func testPauseAndResumeIgnoreRepeats() {
        var pauses = RecordingPauses()
        XCTAssertFalse(pauses.resume(at: 1), "not paused")
        XCTAssertTrue(pauses.pause(at: 2))
        XCTAssertFalse(pauses.pause(at: 3), "already paused")
        XCTAssertTrue(pauses.resume(at: 4))
        XCTAssertEqual(pauses.pauses, [.init(start: 2, end: 4)])
        // A clock that steps back can't make a pause end before it starts.
        pauses.pause(at: 3)
        pauses.resume(at: 2)
        XCTAssertEqual(pauses.pauses.last, .init(start: 4, end: 4))
        XCTAssertEqual(pauses.recordedTime(at: 10), 8)
    }

    func testAudioBufferStraddlingPauses() {
        let pauses = twoPauses
        let rate = 48_000.0

        // Starts 10 ms before the 102 s pause: keeps those 480 samples.
        XCTAssertEqual(pauses.pieces(start: 101.99, count: 1024, rate: rate),
                       [.init(first: 0, count: 480, time: 101.99)])

        // Starts inside the pause and ends 10 ms after it: keeps the last 480 samples,
        // which land right where the first piece left off.
        let tail = pauses.pieces(start: 103.01 - 1024 / rate, count: 1024, rate: rate)
        XCTAssertEqual(tail.map(\.first), [544])
        XCTAssertEqual(tail.map(\.count), [480])
        XCTAssertEqual(tail[0].time, 102, accuracy: 1e-9)

        // Entirely inside a pause: nothing.
        XCTAssertEqual(pauses.pieces(start: 102.5, count: 1024, rate: rate), [])

        // A buffer spanning a whole short pause: both sides kept, joined.
        var short = RecordingPauses()
        short.pause(at: 10.005)
        short.resume(at: 10.010)
        let both = short.pieces(start: 10, count: 1024, rate: rate)
        XCTAssertEqual(both.map(\.first), [0, 480])
        XCTAssertEqual(both.map(\.count), [240, 1024 - 480])
        XCTAssertEqual(both[1].time, 10.005, accuracy: 1e-9)
        XCTAssertEqual(both[0].time + Double(both[0].count) / rate, both[1].time, accuracy: 1e-9)

        // Two pauses inside one long buffer.
        let long = pauses.pieces(start: 101, count: Int(8 * rate), rate: rate)
        XCTAssertEqual(long.map(\.count), [Int(1 * rate), Int(2 * rate), Int(1.5 * rate)])
        XCTAssertEqual(long.map(\.time), [101, 102, 104])
    }

    func testPicturesFromBeforeResumingCountFromTheResume() {
        let pauses = twoPauses
        XCTAssertEqual(pauses.pictureTime(captured: 101.5, at: 101.6), 101.5, "no pause yet")
        XCTAssertEqual(pauses.pictureTime(captured: 101.9, at: 103.02), 103, "screen unchanged across the pause")
        XCTAssertEqual(pauses.pictureTime(captured: 102.5, at: 103.02), 103, "changed while paused")
        XCTAssertEqual(pauses.pictureTime(captured: 103.01, at: 103.02), 103.01, "captured after resuming")
        XCTAssertEqual(pauses.pictureTime(captured: 104, at: 108), 107.5, "the latest pause counts")
    }

    // MARK: - Audio sample buffers

    func testRetimesInterleavedMicrophoneAudio() throws {
        var pauses = RecordingPauses()
        pauses.pause(at: 10.005)
        pauses.resume(at: 11)
        var audio = PausedAudio()

        // Sample i has value i, so it's clear which samples were kept.
        let first = try Self.buffer(start: 10, count: 480, channels: 1, interleaved: true)
        let second = try Self.buffer(start: 10.01, count: 480, channels: 1, interleaved: true)
        let third = try Self.buffer(start: 10.99, count: 960, channels: 1, interleaved: true)

        let a = audio.retime(first, pauses: pauses)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(Self.samples(a[0]).first, (0..<240).map(Float.init), "only before the pause")
        XCTAssertEqual(a[0].presentationTimeStamp.seconds, 10, accuracy: 1e-9)
        XCTAssertEqual(a[0].duration.seconds, 0.005, accuracy: 1e-9)

        XCTAssertEqual(audio.retime(second, pauses: pauses).count, 0, "inside the pause")

        let c = audio.retime(third, pauses: pauses)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(Self.samples(c[0]).first, (480..<960).map(Float.init), "only after resuming")
        XCTAssertEqual(c[0].presentationTimeStamp.seconds, 10.005, accuracy: 1e-6, "continues where it stopped")
        XCTAssertEqual(c[0].duration.seconds, 0.01, accuracy: 1e-9)
    }

    func testRetimesSystemAudioWithOneBufferPerChannel() throws {
        var pauses = RecordingPauses()
        pauses.pause(at: 5.0025)
        pauses.resume(at: 5.005)
        var audio = PausedAudio()

        let buffer = try Self.buffer(start: 5, count: 480, channels: 2, interleaved: false)
        let pieces = audio.retime(buffer, pauses: pauses)
        XCTAssertEqual(pieces.count, 2)
        let head = Self.samples(pieces[0])
        let tail = Self.samples(pieces[1])
        XCTAssertEqual(head[0], (0..<120).map(Float.init))
        XCTAssertEqual(head[1], (0..<120).map { -Float($0) }, "second channel kept apart")
        XCTAssertEqual(tail[0], (240..<480).map(Float.init))
        XCTAssertEqual(tail[1], (240..<480).map { -Float($0) })
        XCTAssertEqual(pieces[1].presentationTimeStamp.seconds, 5.0025, accuracy: 1e-6)
        XCTAssertEqual(CMTimeAdd(pieces[0].presentationTimeStamp, pieces[0].duration), pieces[1].presentationTimeStamp,
                       "no gap or overlap at the cut")
    }

    /// MicrophoneCapture moves buffers onto the host clock with one timing entry holding
    /// the whole buffer's duration. Lengths must still come out right after a pause.
    func testMicrophoneBuffersLabeledPerBuffer() throws {
        func likeMicrophone(_ buffer: CMSampleBuffer) throws -> CMSampleBuffer {
            var timing = CMSampleTimingInfo(duration: buffer.duration, presentationTimeStamp: buffer.presentationTimeStamp,
                                            decodeTimeStamp: .invalid)
            var out: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1,
                                                  sampleTimingArray: &timing, sampleBufferOut: &out)
            return try XCTUnwrap(out)
        }
        var pauses = RecordingPauses()
        pauses.pause(at: 10.005)
        pauses.resume(at: 11)
        var audio = PausedAudio()

        let before = audio.retime(try likeMicrophone(Self.buffer(start: 10, count: 240, channels: 1, interleaved: true)),
                                  pauses: pauses)
        let after = audio.retime(try likeMicrophone(Self.buffer(start: 11, count: 480, channels: 1, interleaved: true)),
                                 pauses: pauses)
        XCTAssertEqual(before.map(\.duration.seconds), [0.005])
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].presentationTimeStamp.seconds, 10.005, accuracy: 1e-9)
        XCTAssertEqual(after[0].duration.seconds, 0.01, accuracy: 1e-9)
        XCTAssertEqual(Self.samples(after[0]).first, (0..<480).map(Float.init))
    }

    func testAudioBeforeAnyPauseIsUntouched() throws {
        var audio = PausedAudio()
        let buffer = try Self.buffer(start: 3, count: 1024, channels: 1, interleaved: true)
        let out = audio.retime(buffer, pauses: RecordingPauses())
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0] === buffer)
    }

    // MARK: - A whole file

    /// Writes 3 seconds of video and audio through AVAssetWriter with two pauses, as the
    /// recorder does, and reads the file back. What was captured during the pauses is
    /// white and loud; everything else is black and silent. The file must be 1.9 s long
    /// with no white frames, no sound, and no gaps.
    func testWrittenFileHasNoPausedContentAndNoGaps() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pauses-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let origin = 1_000.0
        var pauses = RecordingPauses()
        // Half a sample off the frame and sample times, so float error can't decide
        // which side of a pause a sample captured right at its edge falls on.
        let edge = 0.5 / 48_000
        let pauseTimes: [(Double, Double)] = [(origin + 1 + edge, origin + 1.5 + edge), (origin + 2 + edge, origin + 2.6 + edge)]
        func capturedInPause(_ t: Double) -> Bool { pauseTimes.contains { t >= $0.0 && t < $0.1 } }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        // As in the recorder, so the writer doesn't hold one input back to interleave.
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)
        writer.add(audioInput)
        XCTAssertTrue(writer.startWriting())

        // Events in capture order: video every 1/30 s, audio every 1024 samples (which
        // straddle the pause edges). Pauses start and end as their moment passes.
        enum Event { case frame(Double), audio(Double), pause(Double), resume(Double) }
        var events: [(Double, Event)] = []
        for i in 0..<90 { events.append((origin + Double(i) / 30, .frame(origin + Double(i) / 30))) }
        for i in 0..<141 {
            let t = origin + Double(i * 1024) / 48_000
            events.append((t, .audio(t)))
        }
        for (start, end) in pauseTimes {
            events.append((start, .pause(start)))
            events.append((end, .resume(end)))
        }
        // Audio arrives a little after it was captured.
        func arrival(_ event: (Double, Event)) -> Double {
            if case .audio = event.1 { return event.0 + 0.03 }
            return event.0
        }
        events.sort { arrival($0) < arrival($1) }

        var audio = PausedAudio()
        var started = false
        var lastVideo = CMTime.negativeInfinity
        func waitUntilReady(_ input: AVAssetWriterInput) {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
        }
        for (_, event) in events {
            switch event {
            case .pause(let at): pauses.pause(at: at)
            case .resume(let at): pauses.resume(at: at)
            case .frame(let at):
                guard !pauses.isPaused(at: at) else { continue }
                let time = pauses.recordedTime(at: CMTime(seconds: at, preferredTimescale: 1_000_000_000))
                if !started {
                    writer.startSession(atSourceTime: time)
                    started = true
                }
                guard time > lastVideo else { continue }
                lastVideo = time
                waitUntilReady(videoInput)
                adaptor.append(try Self.solidFrame(white: capturedInPause(at), pool: XCTUnwrap(adaptor.pixelBufferPool)),
                               withPresentationTime: time)
            case .audio(let at):
                guard started else { continue }
                let buffer = try Self.buffer(start: at, count: 1024, channels: 1, interleaved: true) { index in
                    capturedInPause(at + Double(index) / 48_000) ? 0.8 * sin(Float(index) * 0.2) : 0
                }
                for piece in audio.retime(buffer, pauses: pauses) {
                    waitUntilReady(audioInput)
                    XCTAssertTrue(audioInput.append(piece))
                }
            }
        }
        let end = pauses.recordedTime(at: CMTime(seconds: origin + 3, preferredTimescale: 1_000_000_000))
        writer.endSession(atSourceTime: end)
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")

        // Read it back.
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.9, accuracy: 0.04)
        let videoTrack = try await asset.loadTracks(withMediaType: .video)[0]
        let audioTrack = try await asset.loadTracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack,
                                                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(videoOut)
        reader.add(audioOut)
        XCTAssertTrue(reader.startReading())

        var frameTimes: [Double] = []
        var brightest = 0
        while let sample = videoOut.copyNextSampleBuffer() {
            frameTimes.append(sample.presentationTimeStamp.seconds)
            brightest = max(brightest, Self.brightest(try XCTUnwrap(sample.imageBuffer)))
        }
        var audioSamples = 0
        var loudest: Float = 0
        while let sample = audioOut.copyNextSampleBuffer() {
            let values = Self.samples(sample)[0]
            audioSamples += values.count
            loudest = max(loudest, values.map(abs).max() ?? 0)
        }

        // 90 frames, minus 15 and 18 captured during the pauses.
        XCTAssertEqual(frameTimes.count, 57)
        XCTAssertLessThan(brightest, 40, "no frame captured during a pause")
        for (a, b) in zip(frameTimes, frameTimes.dropFirst()) {
            XCTAssertLessThan(b - a, 1.5 / 30, "no gap in the video")
        }
        XCTAssertLessThan(loudest, 0.01, "no sound captured during a pause")
        XCTAssertEqual(Double(audioSamples) / 48_000, 1.9, accuracy: 0.05, "the audio has no gaps either")
        print("Pause file test: duration \(duration) s, \(frameTimes.count) frames, video ends \(frameTimes.last ?? 0) s, "
              + "audio \(Double(audioSamples) / 48_000) s, brightest \(brightest), loudest \(loudest)")
    }

    // MARK: - Helpers

    /// 32-bit float audio at 48 kHz. By default channel 0's sample i is i and channel 1's
    /// is -i.
    static func buffer(start: Double, count: Int, channels: Int, interleaved: Bool,
                       value: ((Int) -> Float)? = nil) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: UInt32(4 * (interleaved ? channels : 1)), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * (interleaved ? channels : 1)), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                                      magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                      formatDescriptionOut: &format), noErr)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: try XCTUnwrap(format), sampleCount: count,
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 1_000_000_000),
            packetDescriptions: nil, sampleBufferOut: &buffer), noErr)

        let channelData = (0..<channels).map { channel in
            (0..<count).map { index in value?(index) ?? (channel == 0 ? Float(index) : -Float(index)) }
        }
        let list = AudioBufferList.allocate(maximumBuffers: interleaved ? 1 : channels)
        defer { free(list.unsafeMutablePointer) }
        var storage: [UnsafeMutableRawPointer] = []
        defer { storage.forEach { $0.deallocate() } }
        if interleaved {
            let memory = UnsafeMutableRawPointer.allocate(byteCount: 4 * count * channels, alignment: 16)
            storage.append(memory)
            let floats = memory.bindMemory(to: Float.self, capacity: count * channels)
            for index in 0..<count { for channel in 0..<channels { floats[index * channels + channel] = channelData[channel][index] } }
            list[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(4 * count * channels), mData: memory)
        } else {
            for channel in 0..<channels {
                let memory = UnsafeMutableRawPointer.allocate(byteCount: 4 * count, alignment: 16)
                storage.append(memory)
                memory.bindMemory(to: Float.self, capacity: count).update(from: channelData[channel], count: count)
                list[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(4 * count), mData: memory)
            }
        }
        let out = try XCTUnwrap(buffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            out, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: list.unsafePointer), noErr)
        return out
    }

    /// Each channel's samples, from 32-bit float audio.
    static func samples(_ buffer: CMSampleBuffer) -> [[Float]] {
        let count = CMSampleBufferGetNumSamples(buffer)
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { memory.deallocate() }
        let pointer = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: pointer, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(pointer)
        var channels: [[Float]] = []
        for audioBuffer in list {
            let floats = audioBuffer.mData!.bindMemory(to: Float.self, capacity: Int(audioBuffer.mDataByteSize) / 4)
            let perBuffer = Int(audioBuffer.mNumberChannels)
            for channel in 0..<perBuffer {
                channels.append((0..<count).map { floats[$0 * perBuffer + channel] })
            }
        }
        return channels
    }

    static func solidFrame(white: Bool, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), white ? 255 : 0,
               CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    static func brightest(_ pixels: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        var brightest = 0
        for y in 0..<CVPixelBufferGetHeight(pixels) {
            for x in 0..<CVPixelBufferGetWidth(pixels) {
                brightest = max(brightest, Int(bytes[y * row + x * 4 + 1]))
            }
        }
        return brightest
    }
}
