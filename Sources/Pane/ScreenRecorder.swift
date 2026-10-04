import AVFoundation
import CoreImage
import PaneKit
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noFramesCaptured
    case microphoneUnavailable
    case writerFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noFramesCaptured:
            return "No video was captured."
        case .microphoneUnavailable:
            return "The microphone couldn't be opened. Pick a different one or turn the microphone off."
        case .writerFailed(let error):
            return "Couldn't write the video file. \(error?.localizedDescription ?? "")"
        }
    }
}

/// Captures one display with ScreenCaptureKit, composites the camera circle on top, and
/// writes an MP4.
///
/// Frames are rendered on a fixed clock rather than whenever the screen changes, so the
/// camera keeps moving even while the screen is still. This render step is also where
/// blurring will plug in later.
///
/// Track layout: video, then microphone, then system audio. The mic comes first because
/// most web players only play the first audio track.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Files are written in self-contained pieces this long, so if Pane quits or the Mac
    /// loses power mid-recording, everything but the last piece still plays. Without them
    /// an MP4 can't be opened at all until it's finished.
    static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

    struct Options {
        var captureMicrophone: Bool
        var microphoneID: String?
        var captureSystemAudio: Bool
        /// nil records without a camera circle.
        var cameraStyle: CameraStyle?
        var frameRate: Int = 30
        /// Longest edge of the output video. Keeps H.264 within hardware encoder limits.
        var maxDimension: Int = 3840
        /// Also write the screen without the camera, and the camera on its own, for
        /// editing in Final Cut. Only used when there's a camera.
        var separateClips: SeparateClips.Files?
    }

    /// How the video's timeline lines up with the system clock, for placing the pointer.
    struct Timeline {
        struct Frame {
            /// Seconds into the video.
            var time: Double
            /// System clock time when the screen picture in this frame was captured; the
            /// pointer in the frame is where it was at that moment.
            var captured: Double
        }
        /// Every frame written, in order.
        var frames: [Frame]
        var duration: Double
        /// The video's size in pixels.
        var size: CGSize
    }

    let outputURL: URL
    /// Called on the main queue if the system stops the stream (display unplugged,
    /// "Stop Sharing" clicked in the menu bar, etc.).
    var onUnexpectedStop: ((Error) -> Void)?

    private let camera: CameraEngine?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // Everything below is only touched on `queue`.
    private let queue = DispatchQueue(label: "Pane.ScreenRecorder", qos: .userInitiated)
    private var stream: SCStream?
    private var microphone: MicrophoneCapture?
    private var writer: AVAssetWriter?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var micInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var overlay: CameraOverlay?
    private var clips: SeparateClips?
    private var renderTimer: DispatchSourceTimer?
    private var latestScreen: CVPixelBuffer?
    private var outputRect = CGRect.zero
    private var sessionStarted = false
    private var isStopping = false
    private var startTime = 0.0
    private var lastFrameTime = 0.0
    private var latestScreenTime = 0.0
    private var frameTimings: [Timeline.Frame] = []
    /// Pauses so far. Everything is written at its time with the pauses cut out.
    private var pauses = RecordingPauses()
    private var lastVideoTime = CMTime.negativeInfinity
    private var microphoneAudio = PausedAudio()
    private var systemAudio = PausedAudio()

    init(outputURL: URL, camera: CameraEngine?) {
        self.outputURL = outputURL
        self.camera = camera
    }

    func start(filter: SCContentFilter, options: Options) async throws {
        let (width, height) = Self.outputSize(for: filter, maxDimension: options.maxDimension)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        // Capture twice as often as frames are written, so each frame's picture is
        // never more than half a frame old: the pointer moves more smoothly, and pointer
        // effects line up with it.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate * 2))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = options.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // The microphone is captured separately (see MicrophoneCapture).

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.movieFragmentInterval = Self.fragmentInterval

        let bitRate = max(4_000_000, Int(Double(width * height * options.frameRate) * 0.05))
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: options.frameRate,
                AVVideoMaxKeyFrameIntervalKey: options.frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(videoInput)

        var micInput: AVAssetWriterInput?
        if options.captureMicrophone {
            let input = Self.makeAudioInput(channels: 1, bitRate: 96_000)
            writer.add(input)
            micInput = input
        }

        var systemAudioInput: AVAssetWriterInput?
        if options.captureSystemAudio {
            let input = Self.makeAudioInput(channels: 2, bitRate: 128_000)
            writer.add(input)
            systemAudioInput = input
        }

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error)
        }
        // Extra files are a bonus: if they can't be written, the recording still is.
        let clips = options.cameraStyle == nil ? nil : options.separateClips.flatMap {
            try? SeparateClips(files: $0, width: width, height: height, frameRate: options.frameRate,
                               bitRate: bitRate, microphone: options.captureMicrophone,
                               systemAudio: options.captureSystemAudio)
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        var microphone: MicrophoneCapture?
        if options.captureMicrophone {
            microphone = MicrophoneCapture(deviceID: options.microphoneID, queue: queue) { [weak self] sampleBuffer in
                guard let self, !self.isStopping, self.sessionStarted else { return }
                for piece in self.microphoneAudio.retime(sampleBuffer, pauses: self.pauses) {
                    self.appendAudio(piece, to: self.micInput)
                    self.clips?.appendMicrophone(piece)
                }
            }
            guard microphone != nil else {
                writer.cancelWriting()
                throw RecorderError.microphoneUnavailable
            }
        }

        let canvas = CGSize(width: width, height: height)
        queue.sync {
            self.stream = stream
            self.microphone = microphone
            self.writer = writer
            self.adaptor = adaptor
            self.micInput = micInput
            self.systemAudioInput = systemAudioInput
            self.outputRect = CGRect(origin: .zero, size: canvas)
            self.overlay = options.cameraStyle.map { CameraOverlay(style: $0, canvas: canvas) }
            self.clips = clips
        }

        do {
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            clips?.cancel()
            throw error
        }
        microphone?.start()

        queue.sync {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(options.frameRate), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.renderFrame() }
            timer.resume()
            renderTimer = timer
        }
    }

    /// Stops capture and finalizes the file. Safe to call after the stream already stopped.
    func stop() async throws -> URL {
        let (stream, microphone) = queue.sync { (self.stream, self.microphone) }
        try? await stream?.stopCapture()
        microphone?.stop()

        // Draining the queue guarantees no append is in flight once we flip isStopping.
        let (writer, inputs, sessionStarted, clips) = queue.sync {
            isStopping = true
            renderTimer?.cancel()
            renderTimer = nil
            latestScreen = nil
            let inputs = [adaptor?.assetWriterInput, micInput, systemAudioInput].compactMap { $0 }
            return (self.writer, inputs, self.sessionStarted, self.clips)
        }
        guard let writer else { throw RecorderError.writerFailed(nil) }
        guard sessionStarted else {
            writer.cancelWriting()
            clips?.cancel()
            throw RecorderError.noFramesCaptured
        }

        // Stopped while paused, this is where the pause began.
        let end = queue.sync { pauses.recordedTime(at: CMClockGetTime(CMClockGetHostTimeClock())) }
        writer.endSession(atSourceTime: end)
        inputs.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        await clips?.finish(at: end)

        guard writer.status == .completed else {
            throw RecorderError.writerFailed(writer.error)
        }
        return outputURL
    }

    /// Changes what's left out mid-recording, e.g. a notification banner that just
    /// appeared (see DistractionGuard). The display and video size stay the same.
    func update(filter: SCContentFilter) async throws {
        let stream = queue.sync { isStopping ? nil : self.stream }
        try await stream?.updateContentFilter(filter)
    }

    /// Stops writing until `resume()`. Capture keeps running, so the screen is current
    /// and the camera keeps moving the moment recording resumes.
    func pause() {
        queue.sync { _ = pauses.pause(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds) }
    }

    /// Picks up where `pause()` left off, with no gap in the file.
    func resume() {
        queue.sync { _ = pauses.resume(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds) }
    }

    /// Available once recording has stopped.
    func timeline() -> Timeline? {
        queue.sync {
            guard sessionStarted else { return nil }
            return Timeline(frames: frameTimings, duration: lastFrameTime - startTime, size: outputRect.size)
        }
    }

    // MARK: - Rendering

    private func renderFrame() {
        guard !isStopping, !pauses.isPaused, let writer, writer.status == .writing,
              let screen = latestScreen, let adaptor,
              adaptor.assetWriterInput.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool
        else { return }

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return }

        let screenImage = CIImage(cvPixelBuffer: screen)
        var frame = screenImage
        let cameraFrame = camera?.latestFrame
        if let overlay, let cameraFrame {
            frame = overlay.composite(camera: cameraFrame, over: frame)
        }
        ciContext.render(frame.cropped(to: outputRect), to: output, bounds: outputRect, colorSpace: colorSpace)

        // ScreenCaptureKit timestamps use the host clock too, so audio stays in sync.
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        let now = pauses.recordedTime(at: host)
        guard now > lastVideoTime else { return }
        lastVideoTime = now
        if !sessionStarted {
            writer.startSession(atSourceTime: now)
            clips?.start(at: now)
            sessionStarted = true
            startTime = now.seconds
        }
        lastFrameTime = now.seconds
        frameTimings.append(Timeline.Frame(time: now.seconds - startTime,
                                           captured: pauses.pictureTime(captured: latestScreenTime, at: host.seconds)))
        adaptor.append(output, withPresentationTime: now)

        if let clips, let overlay {
            // The camera on its own: transparent wherever it isn't, so it lines up with
            // the screen exactly when laid on top of it.
            let clear = CIImage(color: .clear).cropped(to: outputRect)
            let cameraLayer = cameraFrame.map { overlay.composite(camera: $0, over: clear) } ?? clear
            clips.append(screen: screenImage, camera: cameraLayer, at: now, in: outputRect,
                         context: ciContext, colorSpace: colorSpace)
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isStopping, sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // Only "complete" frames carry new pixels; others mean nothing changed.
            guard Self.isCompleteFrame(sampleBuffer), let pixels = sampleBuffer.imageBuffer else { return }
            latestScreen = pixels
            latestScreenTime = sampleBuffer.presentationTimeStamp.seconds
        case .microphone:
            break
        case .audio:
            guard sessionStarted else { return }
            for piece in systemAudio.retime(sampleBuffer, pauses: pauses) {
                appendAudio(piece, to: systemAudioInput)
                clips?.appendSystemAudio(piece)
            }
        @unknown default:
            break
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        // Audio that arrives before the first video frame has nowhere to go.
        guard sessionStarted, writer?.status == .writing, let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onUnexpectedStop?(error)
        }
    }

    // MARK: - Helpers

    static func makeAudioInput(channels: Int, bitRate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }

    private static func outputSize(for filter: SCContentFilter, maxDimension: Int) -> (Int, Int) {
        let scale = CGFloat(filter.pointPixelScale)
        var width = filter.contentRect.width * scale
        var height = filter.contentRect.height * scale
        let longest = max(width, height)
        if longest > CGFloat(maxDimension) {
            let factor = CGFloat(maxDimension) / longest
            width *= factor
            height *= factor
        }
        // H.264 wants even dimensions.
        return (Int(width) & ~1, Int(height) & ~1)
    }
}

/// Draws the round camera, its border and a soft shadow onto a video frame.
/// The masks are built once per recording since the layout doesn't change.
struct CameraOverlay {
    private let layout: OverlayLayout
    private let cameraMask: CIImage
    private let borderLayer: CIImage?
    private let shadow: CIImage

    init(style: CameraStyle, canvas: CGSize) {
        let layout = OverlayLayout(style: style, canvas: canvas, topLeftOrigin: false)
        self.layout = layout
        cameraMask = Self.disc(center: layout.center, radius: layout.radius)

        let outer = layout.radius + layout.ring
        borderLayer = layout.ring > 0
            ? CIImage(color: style.borderColor.ciColor).applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: Self.disc(center: layout.center, radius: outer),
            ])
            : nil

        let shortSide = min(canvas.width, canvas.height)
        shadow = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: layout.center.x, y: layout.center.y - shortSide * 0.006),
            "inputRadius0": outer,
            "inputRadius1": outer + shortSide * 0.025,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.35),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])!.outputImage!
    }

    func composite(camera: CIImage, over base: CIImage) -> CIImage {
        let diameter = layout.radius * 2
        let scale = diameter / camera.extent.width
        let placed = camera
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: layout.center.x - layout.radius, y: layout.center.y - layout.radius))

        var frame = shadow.composited(over: base)
        if let borderLayer {
            frame = borderLayer.composited(over: frame)
        }
        return placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: frame,
            kCIInputMaskImageKey: cameraMask,
        ])
    }

    /// An anti-aliased white disc on transparent, for use as an alpha mask.
    private static func disc(center: CGPoint, radius: CGFloat) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: center.x, y: center.y),
            "inputRadius0": radius - 1,
            "inputRadius1": radius,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])!.outputImage!
            .cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
