import AVFoundation
import XCTest
@testable import PaneKit

/// Recordings are written in fragments so a crash keeps them. This writes one the way
/// ScreenRecorder does (host-clock times, audio that starts a little before the first
/// frame, a pause in the middle) and checks the file is finished and whole.
final class FragmentedRecordingTests: XCTestCase {
    func testFragmentedRecordingWithEarlyAudioAndAPause() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fragmented-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        // ScreenRecorder's video settings.
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000, AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        // As in ScreenRecorder; it also keeps either input from waiting on the other here.
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        writer.add(video)
        writer.add(audio)
        XCTAssertTrue(writer.startWriting())

        // Host-clock-like times; paused from 1.0 to 1.6 s after the start.
        let origin = 5_000.0
        var pauses = RecordingPauses()
        var pausedAudio = PausedAudio()
        let sessionStart = CMTime(seconds: origin, preferredTimescale: 1_000_000_000)
        writer.startSession(atSourceTime: sessionStart)

        // Fed in real time, as a recording is: the writer only fails mid-recording then.
        // Audio buffers of 10 ms, one of them straddling the first frame, as a microphone's do.
        var nextVideo = origin, nextAudio = origin - 0.035
        let end = origin + 4.5
        let clock = ContinuousClock(), wallStart = clock.now
        func waitFor(_ time: Double) async throws {
            try await Task.sleep(until: wallStart.advanced(by: .seconds(max(0, time - origin))), clock: clock)
        }
        while nextVideo < end || nextAudio < end {
            if nextAudio <= nextVideo {
                try await waitFor(nextAudio)
                // 10 ms of audio, timed by when it was heard (the first starts before the session).
                if nextAudio >= origin + 1, !pauses.isPaused, pauses.pauses.isEmpty { _ = pauses.pause(at: nextAudio) }
                if nextAudio >= origin + 1.6, pauses.isPaused { _ = pauses.resume(at: nextAudio) }
                let buffer = try RecordingPausesTests.buffer(start: nextAudio, count: 480, channels: 1, interleaved: true)
                for piece in pausedAudio.retime(buffer, pauses: pauses)
                where piece.presentationTimeStamp >= sessionStart {
                    try await waitUntilReady(audio)
                    XCTAssertTrue(audio.append(piece), "audio append failed: \(String(describing: writer.error))")
                }
                nextAudio += 0.01
            } else {
                try await waitFor(nextVideo)
                if !pauses.isPaused(at: nextVideo) {
                    var pixels: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixels)
                    let time = pauses.recordedTime(at: CMTime(seconds: nextVideo, preferredTimescale: 1_000_000_000))
                    try await waitUntilReady(video)
                    XCTAssertTrue(adaptor.append(pixels!, withPresentationTime: time),
                                  "video append failed: \(String(describing: writer.error))")
                }
                nextVideo += 1.0 / 30
            }
        }
        writer.endSession(atSourceTime: pauses.recordedTime(at: CMTime(seconds: end, preferredTimescale: 1_000_000_000)))
        video.markAsFinished()
        audio.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")

        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 3.9, accuracy: 0.05, "4.5 s recorded with a 0.6 s pause")
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        for _ in 0..<2_000 where !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(input.isReadyForMoreMediaData, "writer input never became ready")
    }
}
