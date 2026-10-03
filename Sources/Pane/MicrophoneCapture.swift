import AVFoundation

/// Records the microphone directly, asking for plain 32-bit float audio.
///
/// ScreenCaptureKit can capture the microphone too, but with some USB mics that send
/// 24-bit audio (seen with a Shure MV7+) it sometimes labels the audio with the wrong
/// sample size, and the whole recording comes out as loud static. Capturing it here
/// keeps the format under Pane's control.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue: DispatchQueue
    private let handler: (CMSampleBuffer) -> Void

    /// - Parameters:
    ///   - deviceID: The microphone's unique ID, or nil for the system's default input.
    ///   - queue: Where `handler` is called.
    ///   - handler: Receives audio with timestamps on the system's host clock, the same
    ///     clock the screen recording uses.
    init?(deviceID: String?, queue: DispatchQueue, handler: @escaping (CMSampleBuffer) -> Void) {
        self.queue = queue
        self.handler = handler
        super.init()

        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output)
        else { return nil }

        session.beginConfiguration()
        session.addInput(input)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() {
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // The session may keep time by the mic's own clock; move it onto the host clock
        // so the audio lines up with the video.
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let hostClock = CMClockGetHostTimeClock()
        guard !CFEqual(clock, hostClock) else {
            handler(sampleBuffer)
            return
        }
        let time = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: hostClock)
        var timing = CMSampleTimingInfo(duration: sampleBuffer.duration, presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &retimed)
        handler(retimed ?? sampleBuffer)
    }
}
