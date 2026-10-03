@preconcurrency import AVFoundation
import CoreImage
import Vision

/// Runs the camera, crops it to a square, applies the chosen background, and hands the
/// latest processed frame to both the previews and the recorder.
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Side length of processed frames, in pixels.
    static let frameSize: CGFloat = 720
    private static let previewSize: CGFloat = 480

    /// Receives a small rendered frame for on-screen previews, about 30 times a second.
    var onPreview: (@MainActor (CGImage) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "Pane.Camera", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])

    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let sequenceHandler = VNSequenceRequestHandler()

    private let lock = NSLock()
    private var _latestFrame: CIImage?
    private var _style = CameraStyle()

    // Only touched on `queue`.
    private var cachedBackground: (path: String, image: CIImage)?

    // Only touched on the main thread.
    private(set) var isRunning = false
    private var currentDeviceID: String?

    override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// The most recent processed frame: a `frameSize` square with its origin at zero.
    var latestFrame: CIImage? { lock.withLock { _latestFrame } }

    var style: CameraStyle {
        get { lock.withLock { _style } }
        set { lock.withLock { _style = newValue } }
    }

    /// Starts the camera, or switches to a different one. Returns false if it can't.
    @MainActor
    func start(deviceID: String?) -> Bool {
        if isRunning && deviceID == currentDeviceID { return true }

        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        if session.outputs.isEmpty, session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()

        currentDeviceID = deviceID
        isRunning = true
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            if !session.isRunning { session.startRunning() }
        }
        return true
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        isRunning = false
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        lock.withLock { _latestFrame = nil }
    }

    // MARK: - Frame processing

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let style = self.style
        let camera = CIImage(cvPixelBuffer: pixelBuffer)
        let normalize = Self.squareTransform(for: camera.extent, mirrored: style.mirrored)

        var frame = camera.transformed(by: normalize).cropped(to: Self.frameRect)
        if style.background != .none, let mask = personMask(for: pixelBuffer, cameraExtent: camera.extent) {
            let person = mask.transformed(by: normalize).cropped(to: Self.frameRect)
            frame = frame.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background(for: style, camera: frame),
                kCIInputMaskImageKey: person,
            ])
        }

        lock.withLock { _latestFrame = frame }
        publishPreview(frame)
    }

    private static let frameRect = CGRect(x: 0, y: 0, width: frameSize, height: frameSize)

    /// Center-crops to a square, scales to `frameSize`, and optionally mirrors (selfie view).
    private static func squareTransform(for extent: CGRect, mirrored: Bool) -> CGAffineTransform {
        let side = min(extent.width, extent.height)
        let scale = frameSize / side
        var t = CGAffineTransform(translationX: -(extent.midX - side / 2), y: -(extent.midY - side / 2))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        if mirrored {
            t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1).concatenating(
                CGAffineTransform(translationX: frameSize, y: 0)))
        }
        return t
    }

    /// A mask that is white where a person is, scaled to the camera frame.
    private func personMask(for pixelBuffer: CVPixelBuffer, cameraExtent: CGRect) -> CIImage? {
        guard (try? sequenceHandler.perform([segmentation], on: pixelBuffer)) != nil,
              let maskBuffer = segmentation.results?.first?.pixelBuffer
        else { return nil }
        let mask = CIImage(cvPixelBuffer: maskBuffer)
        return mask.transformed(by: CGAffineTransform(
            scaleX: cameraExtent.width / mask.extent.width,
            y: cameraExtent.height / mask.extent.height
        ))
    }

    private func background(for style: CameraStyle, camera: CIImage) -> CIImage {
        let solid = CIImage(color: style.backgroundColor.ciColor).cropped(to: Self.frameRect)
        switch style.background {
        case .none:
            return camera
        case .blur:
            return camera.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: Self.frameRect)
        case .color:
            return solid
        case .image:
            return style.backgroundImagePath.flatMap(loadBackground) ?? solid
        }
    }

    /// Loads and aspect-fills a background image to the frame square, cached by path.
    private func loadBackground(path: String) -> CIImage? {
        if let cached = cachedBackground, cached.path == path { return cached.image }
        guard let source = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true])
        else { return nil }
        let extent = source.extent
        let scale = max(Self.frameSize / extent.width, Self.frameSize / extent.height)
        let scaled = source
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let fitted = scaled
            .transformed(by: CGAffineTransform(
                translationX: (Self.frameSize - scaled.extent.width) / 2,
                y: (Self.frameSize - scaled.extent.height) / 2))
            .cropped(to: Self.frameRect)
        cachedBackground = (path, fitted)
        return fitted
    }

    private func publishPreview(_ frame: CIImage) {
        guard let onPreview else { return }
        let scale = Self.previewSize / Self.frameSize
        let small = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(
            small, from: CGRect(x: 0, y: 0, width: Self.previewSize, height: Self.previewSize))
        else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onPreview(image) }
        }
    }
}
