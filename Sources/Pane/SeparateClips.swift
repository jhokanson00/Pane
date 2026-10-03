import AVFoundation
import CoreImage
import VideoToolbox

/// The screen without the camera, and the camera circle on its own over transparency,
/// written alongside a recording so Final Cut can keep the camera on its own layer.
/// Both are full-frame and share the recording's clock, so laid on top of each other
/// they line up exactly. Only used on the recorder's queue.
final class SeparateClips {
    struct Files {
        var screen: URL
        var camera: URL
    }

    private let screenWriter: AVAssetWriter
    private let screenAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let microphoneInput: AVAssetWriterInput?
    private let systemAudioInput: AVAssetWriterInput?
    private let cameraWriter: AVAssetWriter
    private let cameraAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private var isWriting = false

    init(files: Files, width: Int, height: Int, frameRate: Int, bitRate: Int,
         microphone: Bool, systemAudio: Bool) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: files.screen.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: files.screen)
        try? fileManager.removeItem(at: files.camera)
        let pixels: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]

        // The screen, as the recording itself is written, with the same audio.
        screenWriter = try AVAssetWriter(outputURL: files.screen, fileType: .mp4)
        let screenInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
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
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        screenInput.expectsMediaDataInRealTime = true
        screenAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: screenInput,
                                                             sourcePixelBufferAttributes: pixels)
        screenWriter.add(screenInput)
        microphoneInput = microphone ? ScreenRecorder.makeAudioInput(channels: 1, bitRate: 96_000) : nil
        systemAudioInput = systemAudio ? ScreenRecorder.makeAudioInput(channels: 2, bitRate: 128_000) : nil
        for input in [microphoneInput, systemAudioInput].compactMap({ $0 }) { screenWriter.add(input) }

        // The camera: HEVC with an alpha channel, which Final Cut shows as transparent.
        // Mostly empty, so it stays small.
        cameraWriter = try AVAssetWriter(outputURL: files.camera, fileType: .mov)
        let cameraInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, bitRate / 3),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                // Core Image draws with premultiplied alpha.
                kVTCompressionPropertyKey_AlphaChannelMode as String: kVTAlphaChannelMode_PremultipliedAlpha,
                kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.9,
            ] as [String: Any],
        ])
        cameraInput.expectsMediaDataInRealTime = true
        cameraAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: cameraInput,
                                                             sourcePixelBufferAttributes: pixels)
        cameraWriter.add(cameraInput)

        guard screenWriter.startWriting(), cameraWriter.startWriting() else {
            for writer in [screenWriter, cameraWriter] where writer.status == .writing { writer.cancelWriting() }
            throw RecorderError.writerFailed(screenWriter.error ?? cameraWriter.error)
        }
    }

    func start(at time: CMTime) {
        screenWriter.startSession(atSourceTime: time)
        cameraWriter.startSession(atSourceTime: time)
        isWriting = true
    }

    func append(screen: CIImage, camera: CIImage, at time: CMTime, in rect: CGRect,
                context: CIContext, colorSpace: CGColorSpace) {
        guard isWriting else { return }
        for (image, adaptor, writer) in [(screen, screenAdaptor, screenWriter), (camera, cameraAdaptor, cameraWriter)] {
            // Appending to a writer that has failed raises an exception, which would end
            // the recording too.
            guard writer.status == .writing, adaptor.assetWriterInput.isReadyForMoreMediaData,
                  let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            context.render(image.cropped(to: rect), to: buffer, bounds: rect, colorSpace: colorSpace)
            adaptor.append(buffer, withPresentationTime: time)
        }
    }

    func appendMicrophone(_ sample: CMSampleBuffer) { append(sample, to: microphoneInput) }

    func appendSystemAudio(_ sample: CMSampleBuffer) { append(sample, to: systemAudioInput) }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard isWriting, screenWriter.status == .writing, let input, input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    func finish(at time: CMTime) async {
        isWriting = false
        for writer in [screenWriter, cameraWriter] {
            guard writer.status == .writing else {
                writer.cancelWriting()
                continue
            }
            writer.endSession(atSourceTime: time)
            writer.inputs.forEach { $0.markAsFinished() }
            await writer.finishWriting()
        }
    }

    func cancel() {
        isWriting = false
        for writer in [screenWriter, cameraWriter] where writer.status == .writing {
            writer.cancelWriting()
        }
    }
}
