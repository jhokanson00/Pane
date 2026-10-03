import AVFoundation
import CoreImage

public enum ExportError: LocalizedError {
    case noVideoTrack
    case failed(Error?)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The recording has no video."
        case .failed(let error): "Couldn't export the video. \(error?.localizedDescription ?? "")"
        }
    }
}

/// Writes a copy of a recording with every enabled finding covered by a frosted blur,
/// and effects (pointer effects and the like) drawn on top. Audio is copied across
/// untouched, unless there are click sounds to mix in.
public enum RedactionExporter {
    /// - Parameters:
    ///   - clickSounds: Clicks to hear in the first audio track. With none, the
    ///     audio is copied across untouched.
    ///   - timeRange: The part to keep, in seconds of the source (see `Trim`);
    ///     nil keeps the whole video. Blurs and effects are placed by source time, so they
    ///     stay put; the copy itself starts at zero and lasts exactly as long as the range.
    public static func export(
        source: URL,
        to destination: URL,
        findings: [Finding],
        effects: [any FrameEffect] = [],
        clickSounds: [PointerTrack.Click] = [],
        timeRange: ClosedRange<Double>? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let size = try await videoTrack.load(.naturalSize)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let dataRate = try await videoTrack.load(.estimatedDataRate)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioFormats: [CMFormatDescription?] = []
        for track in audioTracks {
            audioFormats.append(try await track.load(.formatDescriptions).first)
        }
        let enabled = findings.filter(\.isEnabled)

        let job = ExportJob(
            asset: asset, destination: destination, videoTrack: videoTrack, audioTracks: audioTracks,
            audioFormats: audioFormats, size: size, frameRate: frameRate, dataRate: dataRate,
            duration: duration, findings: enabled, effects: effects, progress: progress
        )
        job.keep = Trim.normalized(timeRange, duration: duration).map {
            CMTimeRange(start: CMTime(seconds: $0.lowerBound, preferredTimescale: 600_000),
                        end: CMTime(seconds: $0.upperBound, preferredTimescale: 600_000))
        }
        job.clickSounds = clickSounds.isEmpty ? nil : ClickSoundMixer(clicks: clickSounds)
        try await withTaskCancellationHandler {
            try await job.run()
        } onCancel: {
            job.cancel()
        }
    }
}

private final class ExportJob: @unchecked Sendable {
    let asset: AVAsset
    let destination: URL
    let videoTrack: AVAssetTrack
    let audioTracks: [AVAssetTrack]
    let audioFormats: [CMFormatDescription?]
    let size: CGSize
    let frameRate: Float
    let dataRate: Float
    let duration: Double
    let findings: [Finding]
    let effects: [any FrameEffect]
    let progress: @Sendable (Double) -> Void
    /// The part of the source to write, shifted to start at zero; nil writes it all.
    var keep: CMTimeRange?
    /// Mixed into the first audio track (or a new one, if there's no audio).
    var clickSounds: ClickSoundMixer?

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let cancelLock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    init(asset: AVAsset, destination: URL, videoTrack: AVAssetTrack, audioTracks: [AVAssetTrack],
         audioFormats: [CMFormatDescription?], size: CGSize, frameRate: Float, dataRate: Float,
         duration: Double, findings: [Finding], effects: [any FrameEffect],
         progress: @escaping @Sendable (Double) -> Void) {
        self.asset = asset
        self.destination = destination
        self.videoTrack = videoTrack
        self.audioTracks = audioTracks
        self.audioFormats = audioFormats
        self.size = size
        self.frameRate = frameRate
        self.dataRate = dataRate
        self.duration = duration
        self.findings = findings
        self.effects = effects
        self.progress = progress
    }

    var isCancelled: Bool { cancelLock.withLock { cancelled } }

    func cancel() {
        cancelLock.withLock { cancelled = true }
    }

    func run() async throws {
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        // With click sounds, the first track is decoded so they can be mixed in. A trimmed
        // copy decodes every track: the reader then cuts the sound to the range exactly,
        // on the timeline. (Copied AAC packets carry the encoder's delay, and a copied
        // buffer running past the end hangs the writer's endSession.)
        let decodes = audioTracks.indices.map { keep != nil || ($0 == 0 && clickSounds != nil) }
        let audioOutputs = audioTracks.enumerated().map { index, track in
            AVAssetReaderTrackOutput(track: track, outputSettings: decodes[index] ? ClickSoundAudio.decodedSettings : nil)
        }
        audioOutputs.forEach { reader.add($0) }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let width = Int(size.width)
        let height = Int(size.height)
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
                AVVideoAverageBitRateKey: max(4_000_000, Int(dataRate)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(videoInput)
        let audioInputs = audioFormats.enumerated().map { index, format in
            decodes[index]
                ? AVAssetWriterInput(mediaType: .audio, outputSettings: ClickSoundAudio.encodedSettings(like: format))
                : AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        }
        audioInputs.forEach { writer.add($0) }
        // A recording with no audio gets one track with just the clicks.
        let clickOnly = audioTracks.isEmpty
            ? clickSounds.map { ClickOnlyAudio(mixer: $0, from: keep?.start.seconds ?? 0, to: keep?.end.seconds ?? duration) }
            : nil
        let clickOnlyInput = clickOnly.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: ClickSoundAudio.encodedSettings(like: nil))
        }
        if let clickOnlyInput { writer.add(clickOnlyInput) }

        if let keep {
            reader.timeRange = keep
            // Edits are timed in the movie's units, 1/600 s by default: too coarse for
            // sound that starts a few milliseconds after the picture.
            writer.movieTimeScale = 48_000
        }
        self.reader = reader
        self.writer = writer
        guard reader.startReading() else { throw ExportError.failed(reader.error) }
        guard writer.startWriting() else { throw ExportError.failed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let shift = keep?.start ?? .zero
        let length = keep?.duration.seconds ?? duration
        var lastFrame: CMTime?
        var lastPixels: CVPixelBuffer?
        pump(input: videoInput, label: "video", group: group) { [self] in
            guard !isCancelled else { return false }
            guard let sample = videoOutput.copyNextSampleBuffer() else {
                // The writer gives the last frame the length of the one before, so the
                // picture can end a little early. The same frame again right at the end
                // makes it last until then; the session's end cuts the copy itself off.
                if let keep, let pixels = lastPixels, let last = lastFrame, last < keep.duration {
                    adaptor.append(pixels, withPresentationTime: keep.duration)
                    lastPixels = nil
                    return true
                }
                return false
            }
            let time = sample.presentationTimeStamp
            guard let pixels = sample.imageBuffer else { return true }
            // A frame that began just before the kept part is what shows at its start.
            var outputTime = CMTimeMaximum(time - shift, .zero)
            if let keep {
                guard time < keep.end, lastFrame.map({ outputTime > $0 }) ?? true else { return true }
                if lastFrame == nil { outputTime = .zero }
            }
            let output = redact(pixels, at: time.seconds, pool: adaptor.pixelBufferPool) ?? pixels
            adaptor.append(output, withPresentationTime: outputTime)
            lastFrame = outputTime
            if keep != nil { lastPixels = output }
            progress(min(1, outputTime.seconds / max(length, 0.001)))
            return true
        }
        for (index, (output, input)) in zip(audioOutputs, audioInputs).enumerated() {
            let mixer = index == 0 ? clickSounds : nil
            pump(input: input, label: "audio", group: group) { [self] in
                guard !isCancelled, let read = output.copyNextSampleBuffer() else { return false }
                // Clicks are placed by source time, so they're mixed in before the shift.
                let sample = mixer.flatMap { ClickSoundAudio.mixed(read, with: $0) } ?? read
                if let keep {
                    guard sample.numSamples > 0, sample.presentationTimeStamp - shift < keep.duration,
                          let shifted = Self.shifted(sample, by: shift) else { return true }
                    input.append(shifted)
                } else {
                    input.append(sample)
                }
                return true
            }
        }
        if let clickOnly, let clickOnlyInput {
            pump(input: clickOnlyInput, label: "clicks", group: group) { [self] in
                guard !isCancelled, let sample = clickOnly.next() else { return false }
                clickOnlyInput.append(sample)
                return true
            }
        }
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }

        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.failed(reader.error)
        }
        if let keep { writer.endSession(atSourceTime: keep.duration) }
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.failed(writer.error) }
        progress(1)
    }

    /// A copy of `sample` moved earlier by `shift`.
    private static func shifted(_ sample: CMSampleBuffer, by shift: CMTime) -> CMSampleBuffer? {
        guard var timings = try? sample.sampleTimingInfos() else { return nil }
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp - shift
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp - shift
            }
        }
        return try? CMSampleBuffer(copying: sample, withNewTiming: timings)
    }

    /// Feeds an input from `next` until it returns false.
    private func pump(input: AVAssetWriterInput, label: String, group: DispatchGroup, next: @escaping () -> Bool) {
        group.enter()
        let queue = DispatchQueue(label: "Pane.Export.\(label)")
        var done = false
        input.requestMediaDataWhenReady(on: queue) {
            while !done && input.isReadyForMoreMediaData {
                if !next() {
                    done = true
                    input.markAsFinished()
                    group.leave()
                }
            }
        }
    }

    /// Returns a new frame with blurred regions and effects, or nil if this frame has
    /// neither.
    private func redact(_ pixels: CVPixelBuffer, at time: Double, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        let blurring = findings.contains { $0.coverRect(at: time, aspect: size.width / max(size.height, 1)) != nil }
        let drawing = effects.isActive(at: time)
        guard blurring || drawing, let pool else { return nil }

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return nil }

        let frame = CIImage(cvPixelBuffer: pixels)
        var image = blurring ? Redaction.apply(to: frame, findings: findings, at: time) : frame
        image = effects.apply(to: image, at: time)
        context.render(image, to: output, bounds: frame.extent, colorSpace: colorSpace)
        return output
    }
}

/// The frosted-glass look, shared by export and the review window's preview.
public enum Redaction {
    /// Every enabled finding that's on screen at `time`, in its own shape.
    public static func apply(to frame: CIImage, findings: [Finding], at time: Double) -> CIImage {
        let aspect = frame.extent.width / max(frame.extent.height, 1)
        let areas = findings.compactMap { finding in
            finding.coverRect(at: time, aspect: aspect).map { (rect: $0, shape: finding.shape) }
        }
        return areas.isEmpty ? frame : apply(to: frame, areas: areas)
    }

    /// - Parameter rects: Normalized, bottom-left-origin areas to cover.
    public static func apply(to frame: CIImage, rects: [CGRect]) -> CIImage {
        apply(to: frame, areas: rects.map { (rect: $0, shape: .rectangle) })
    }

    /// - Parameter areas: Normalized, bottom-left-origin areas to cover, each filled in
    ///   its shape.
    public static func apply(to frame: CIImage, areas: [(rect: CGRect, shape: BlurShape)]) -> CIImage {
        let extent = frame.extent
        let source = frame.clampedToExtent()
        // About one letter wide at normal reading sizes for this video.
        let baseCell = max(6, extent.height * 0.0065)
        // A faint, soft grain gives the glass its frosted texture.
        let grain = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingGaussianBlur(sigma: 0.7)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0.025),
            ])
        // The frost is laid on in ordinary screen colors. In Core Image's default linear
        // light, a light white wash turns dark backgrounds into flat light-gray slabs.
        let tint = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.12, colorSpace: passThrough)!)

        var output = frame
        for (normalized, shape) in areas {
            let rect = CGRect(x: extent.minX + normalized.minX * extent.width,
                              y: extent.minY + normalized.minY * extent.height,
                              width: normalized.width * extent.width,
                              height: normalized.height * extent.height)
            // Kept whole (and at its exact position) even when partly off screen, so its
            // tiles and size stay steady as it moves; the result is cut to the frame.
            guard rect.intersects(extent) else { continue }

            // Averaging the area into tiles about one letter wide throws away the letter
            // detail for good, so the text can't be recovered from the blur. Each tile
            // is a true average (not one sampled pixel) and the tiles move with the
            // text, so scrolling doesn't flicker. Bigger text gets bigger tiles.
            let cell = max(baseCell, min(rect.height * 0.22, baseCell * 2.5))
            let tiles = source
                .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: cell / 2])
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: cell,
                    kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
                ])
                .applyingGaussianBlur(sigma: cell * 0.8)
            // Tiles over words come out darker than tiles over the gaps, so on a light
            // background the words' lengths and spacing still show as smudges. Drawing
            // the tiles most of the way toward the area's average color evens them out,
            // leaving just a hint of what's behind for the frosted look.
            let average = source
                .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect.intersection(extent))])
                .clampedToExtent()
            let glass = tiles.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: average,
                kCIInputTimeKey: 0.7,
            ])
            let texture = grain.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            // A little bigger than the rounded shape, so its soft edge never shows through to
            // empty pixels (which would draw a thin dark outline).
            let area = rect.insetBy(dx: -2, dy: -2)
            let screenGlass = glass.cropped(to: area).matchedFromWorkingSpace(to: screenColors) ?? glass
            let frostedScreen = texture.composited(over: tint.composited(over: screenGlass)).cropped(to: area)
            let frosted = frostedScreen.matchedToWorkingSpace(from: screenColors) ?? frostedScreen

            let mask = switch shape {
            case .rectangle: roundedRect(rect, radius: min(min(rect.width, rect.height) * 0.25, baseCell * 1.6))
            case .ellipse: ellipse(rect)
            }
            output = frosted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: mask,
            ])
        }
        return output.cropped(to: extent)
    }

    /// A white oval filling `rect`, with an edge about a pixel soft.
    private static func ellipse(_ rect: CGRect) -> CIImage {
        // A unit circle, stretched to the rect.
        let radius: CGFloat = 1000
        let soft = radius * 2 / max(min(rect.width, rect.height), 1)
        let circle = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputRadius0": max(radius - soft, 0),
            "inputRadius1": radius,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])!.outputImage!
        return circle
            .transformed(by: CGAffineTransform(scaleX: rect.width / (2 * radius), y: rect.height / (2 * radius))
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
            .cropped(to: rect)
    }

    private static let screenColors = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Colors given in this space pass through unchanged, so they stay screen colors.
    private static let passThrough = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": CIColor.white,
        ])!.outputImage!
    }
}
