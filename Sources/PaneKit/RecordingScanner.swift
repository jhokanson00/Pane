import AVFoundation
import Vision

public enum ScanError: LocalizedError {
    case noVideoTrack
    case readFailed(Error?)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The recording has no video."
        case .readFailed(let error): "Couldn't read the recording. \(error?.localizedDescription ?? "")"
        }
    }
}

public struct ScanResult: Sendable {
    public var findings: [Finding]
    /// All text read from each sampled frame, for picking more things to blur later.
    public var frames: [FrameText]
    public var interval: Double
    public var duration: Double
    /// Times of frames where much of the screen changed (scrolling, switching pages).
    var changes: [Double] = []
    /// Where the final check still saw sensitive text the blurs don't cover, in seconds.
    public var stillShowing: [Double] = []
}

/// Notices when much of the screen changes from one frame to the next, which is where
/// text is most likely to slip past the blurs. The pointer or a camera bubble alone
/// doesn't count.
struct ChangeDetector {
    private var previous: [UInt8] = []

    mutating func isChanging(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return false }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)

        // A sparse grid of brightness values is plenty to see a scroll.
        let step = max(1, width / 240)
        var current: [UInt8] = []
        current.reserveCapacity((width / step) * (height / step))
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) { current.append(pixels[y * bytesPerRow + x]) }
        }
        defer { previous = current }
        guard previous.count == current.count else { return false }
        let changed = zip(previous, current).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 24 ? 1 : 0) }
        return Double(changed) / Double(current.count) > 0.03
    }
}

/// Reads the text in a recording a few times a second and finds sensitive information.
public enum RecordingScanner {
    public static func scan(
        url: URL,
        options: SensitiveDetector.Options,
        samplesPerSecond: Double = 3,
        verify: Bool = true,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ScanResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ScanError.noVideoTrack
        }

        // Reading text is most of the work; following it frame by frame and checking the
        // result are the rest.
        var result = try await Task.detached(priority: .userInitiated) {
            try scanFrames(asset: asset, track: track, duration: duration, options: options,
                           interval: 1 / samplesPerSecond, progress: { progress($0 * 0.5) })
        }.value
        result.findings = try await MotionTracker.refine(
            findings: result.findings, url: url, interval: result.interval,
            progress: { progress(0.5 + $0 * 0.1) }
        )
        if verify {
            try await closeLeaks(in: &result, url: url, options: options) { progress(0.6 + $0 * 0.4) }
        }
        progress(1)
        return result
    }

    /// Fast scrolls blur the text in the frames between readings, so the tracking can
    /// lose it. Reads every other frame, adds any text the blurs miss as extra readings,
    /// and tracks again, until nothing is missed.
    ///
    /// The first round checks wherever the screen is changing and around where each
    /// blur starts and stops; the scan's readings are enough while the screen is still.
    /// Later rounds only re-check around the misses, since nothing else changed.
    static func closeLeaks(
        in result: inout ScanResult, url: URL, options: SensitiveDetector.Options, rounds: Int = 4,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let duration = result.duration
        func around(_ time: Double, _ before: Double, _ after: Double) -> ClosedRange<Double> {
            max(0, time - before)...min(duration, time + after)
        }
        var ranges = merged(result.changes.map { around($0, 0.2, 0.2) }
            + result.findings.filter { $0.kind != .manual }.flatMap {
                [around($0.start, 0.7, 0.3), around($0.end, 0.3, 0.7)]
            })
        var previous: [Double] = []
        for round in 0..<rounds {
            // The first round checks the whole video and takes most of the time.
            let share = round == 0 ? (0.0, 0.8) : (0.8 + 0.2 * Double(round - 1) / Double(rounds - 1), 0.2 / Double(rounds - 1))
            // Reading whole frames only: the scan's own readings already looked closely
            // for small text, and once found it's held as long as it's on screen. What
            // this catches is text lost in fast moves, which is rarely small.
            let report = try await LeakAudit.run(url: url, findings: result.findings, options: options, ranges: ranges,
                                                 thorough: false, progress: { progress(share.0 + $0 * share.1) })
            let times = report.leaks.map(\.time)
            // Nothing left, or the extra readings didn't help: say where, rather than
            // let "found N items" sound like everything is covered.
            result.stillShowing = times
            guard !report.frames.isEmpty, times != previous else { return }
            previous = times

            for frame in report.frames {
                if let index = result.frames.firstIndex(where: { abs($0.time - frame.time) < 0.001 }) {
                    // The scan read this frame too, more closely; keep what both found.
                    result.frames[index].matches = combined(result.frames[index].matches + frame.matches)
                    result.frames[index].words = combined(result.frames[index].words + frame.words)
                } else {
                    result.frames.append(frame)
                }
            }
            result.frames.sort { $0.time < $1.time }
            let rebuilt = FindingTracker.build(frames: result.frames, boxes: \.matches,
                                               interval: result.interval, duration: result.duration)
            result.findings = try await MotionTracker.refine(findings: rebuilt, url: url, interval: result.interval)
            ranges = merged(times.map { around($0, 1.5, 1.5) })
        }
    }

    /// Overlapping ranges joined, sorted.
    static func merged(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func scanFrames(
        asset: AVAsset, track: AVAssetTrack, duration: Double, options: SensitiveDetector.Options,
        interval: Double, progress: @escaping @Sendable (Double) -> Void
    ) throws -> ScanResult {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ScanError.readFailed(reader.error) }

        let detector = SensitiveDetector(options: options)
        let lock = NSLock()
        var frames: [FrameText] = []

        // Text recognition is the slow part, so run a few frames at once.
        let ocrQueue = DispatchQueue(label: "Pane.Scanner.OCR", qos: .userInitiated, attributes: .concurrent)
        let inFlight = DispatchSemaphore(value: 3)
        let group = DispatchGroup()

        var nextSampleTime = 0.0
        var changeDetector = ChangeDetector()
        var changes: [Double] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            let time = sampleBuffer.presentationTimeStamp.seconds
            guard let pixels = sampleBuffer.imageBuffer else { continue }
            if changeDetector.isChanging(pixels) { changes.append(time) }
            guard time + 0.001 >= nextSampleTime else { continue }
            nextSampleTime = time + interval

            inFlight.wait()
            group.enter()
            ocrQueue.async {
                defer {
                    inFlight.signal()
                    group.leave()
                }
                let frame = recognize(pixels, at: time, detector: detector)
                lock.withLock { frames.append(frame) }
                progress(min(1, time / max(duration, 0.001)))
            }
        }
        group.wait()

        if reader.status == .failed { throw ScanError.readFailed(reader.error) }

        frames.sort { $0.time < $1.time }
        let findings = FindingTracker.build(frames: frames, boxes: \.matches, interval: interval, duration: duration)
        return ScanResult(findings: findings, frames: frames, interval: interval, duration: duration, changes: changes)
    }

    /// Where text is read in each frame: the whole frame, then each quarter with a
    /// little overlap. Vision shrinks every image to a fixed working size before reading
    /// it, so on a whole 1560×960 frame, 7-pixel text (an account's email under its
    /// name) is too small to read most of the time; a quarter keeps it twice as big. The
    /// whole frame still catches long lines a quarter would cut in two.
    /// (Measured on a Gmail recording: the small email was read on 24 of 35 frames
    /// whole, 35 of 35 in quarters. Upscaling the whole frame didn't help at all.)
    static let readingAreas: [CGRect] = {
        let overlap = 0.06
        var areas = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        for row in 0..<2 {
            for column in 0..<2 {
                areas.append(CGRect(x: Double(column) * 0.5 - overlap, y: Double(row) * 0.5 - overlap,
                                    width: 0.5 + 2 * overlap, height: 0.5 + 2 * overlap)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1)))
            }
        }
        return areas
    }()

    /// - Parameter thorough: Read the quarters as well as the whole frame.
    static func recognize(_ pixels: CVPixelBuffer, at time: Double, detector: SensitiveDetector,
                          thorough: Bool = true) -> FrameText {
        let requests = (thorough ? readingAreas : [readingAreas[0]]).map { area in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Correction would "fix" keys and codes into real words.
            request.usesLanguageCorrection = false
            request.regionOfInterest = area
            return request
        }
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform(requests)

        var matches: [TextBox] = []
        var words: [TextBox] = []
        InkSnapper.with(pixels) { snapper in
            for request in requests {
                let area = request.regionOfInterest
                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let line = candidate.string
                    // Split on spaces only, so emails, URLs and keys stay whole.
                    let tokens = tokenRanges(in: line)
                    for match in detector.matches(in: line) {
                        let rect = box(for: match.range, in: line, tokens: tokens, candidate: candidate,
                                       area: area, snapper: snapper)
                            ?? frameRect(observation.boundingBox, in: area)
                        matches.append(TextBox(text: String(match.text), rect: rect, kind: match.kind))
                    }
                    for range in tokens {
                        guard let rect = box(for: range, in: line, tokens: tokens, candidate: candidate,
                                             area: area, snapper: snapper) else { continue }
                        words.append(TextBox(text: String(line[range]), rect: rect, kind: .customWord))
                    }
                }
            }
        }
        return FrameText(time: time, matches: combined(matches), words: combined(words))
    }

    /// The same text read in two overlapping areas becomes one box covering both readings.
    static func combined(_ boxes: [TextBox]) -> [TextBox] {
        var result: [TextBox] = []
        for box in boxes {
            if let index = result.firstIndex(where: { other in
                guard other.kind == box.kind else { return false }
                let overlap = other.rect.intersection(box.rect)
                guard !overlap.isNull else { return false }
                // Mostly the same spot: one reading may be a cut-off part of the other.
                let smaller = min(other.rect.width * other.rect.height, box.rect.width * box.rect.height)
                return smaller > 0 && overlap.width * overlap.height / smaller > 0.6
            }) {
                let longer = result[index].text.count >= box.text.count ? result[index].text : box.text
                result[index] = TextBox(text: longer, rect: result[index].rect.union(box.rect), kind: box.kind)
            } else {
                result.append(box)
            }
        }
        return result
    }

    /// A box Vision gave relative to `area`, relative to the whole frame.
    static func frameRect(_ rect: CGRect, in area: CGRect) -> CGRect {
        CGRect(x: area.minX + rect.minX * area.width, y: area.minY + rect.minY * area.height,
               width: rect.width * area.width, height: rect.height * area.height)
    }

    /// A tight box around `range`, relative to the whole frame. Vision only measures whole
    /// words reliably, so a match inside a word (`API_KEY=sk-…`) is estimated by
    /// character position, erring toward covering a little extra rather than letting
    /// part of a secret show.
    static func box(
        for range: Range<String.Index>, in line: String, tokens: [Range<String.Index>],
        candidate: VNRecognizedText, area: CGRect, snapper: InkSnapper?
    ) -> CGRect? {
        let overlapping = tokens.filter { $0.overlaps(range) }
        guard let first = overlapping.first, let last = overlapping.last else { return nil }
        let span = first.lowerBound..<last.upperBound
        guard let areaBox = try? candidate.boundingBox(for: span)?.boundingBox else { return nil }
        let spanBox = frameRect(areaBox, in: area)

        let startsOnWord = range.lowerBound == span.lowerBound
        let endsOnWord = range.upperBound == span.upperBound
        var rect = spanBox
        if !startsOnWord || !endsOnWord {
            let total = Double(line[span].count)
            let before = Double(line[span.lowerBound..<range.lowerBound].count)
            let inside = Double(line[range].count)
            let charWidth = spanBox.width / max(total, 1)
            let minX = startsOnWord ? spanBox.minX : spanBox.minX + charWidth * max(0, before - 1.5)
            let maxX = endsOnWord ? spanBox.maxX : min(spanBox.maxX, spanBox.minX + charWidth * (before + inside + 1))
            rect = CGRect(x: minX, y: spanBox.minY, width: maxX - minX, height: spanBox.height)
        }
        return snapper?.snap(rect, snapLeft: startsOnWord, snapRight: endsOnWord) ?? rect
    }

    static func tokenRanges(in line: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in line.indices {
            if line[index].isWhitespace {
                if let s = start { ranges.append(s..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let s = start { ranges.append(s..<line.endIndex) }
        return ranges
    }
}
