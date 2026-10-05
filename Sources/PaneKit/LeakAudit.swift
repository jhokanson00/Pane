import AVFoundation

/// Double-checks a set of blurs against the video itself: reads the text on many more
/// frames than the scan does and reports sensitive text that's on screen but not
/// covered.
public enum LeakAudit {
    public struct Leak: Sendable {
        public var time: Double
        public var text: String
        public var kind: SensitiveKind
        /// Normalized, bottom-left origin.
        public var rect: CGRect
        /// How much of it the blurs cover (0–1).
        public var covered: Double
    }

    public struct Report: Sendable {
        /// Sorted by time.
        public var leaks: [Leak]
        /// Everything read on the frames that had a leak, to use as extra readings.
        public var frames: [FrameText]
    }

    /// Text counts as hidden when the blurs cover at least this much of it.
    static let enough = 0.9

    /// - Parameters:
    ///   - every: Check every nth frame.
    ///   - offset: Which of each `every` frames to check, so a second audit can look at
    ///     frames the first one didn't.
    ///   - ranges: Only check these stretches of the video, in seconds; nil checks it all.
    ///   - thorough: Also read each quarter of the frame, for small text (about three
    ///     times the work).
    public static func run(
        url: URL, findings: [Finding], options: SensitiveDetector.Options,
        every: Int = 2, offset: Int = 0, ranges: [ClosedRange<Double>]? = nil, thorough: Bool = true,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Report {
        if let ranges, ranges.isEmpty { return Report(leaks: [], frames: []) }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ScanError.noVideoTrack }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let frameRate = Double(max(try await track.load(.nominalFrameRate), 1))
        let aspect = size.width / max(size.height, 1)

        let ranges = ranges ?? [0...duration]
        return try await Task.detached(priority: .userInitiated) {
            try check(asset: asset, track: track, findings: findings, options: options, thorough: thorough, aspect: aspect,
                      frameRate: frameRate, every: every, offset: offset, ranges: ranges, progress: progress)
        }.value
    }

    private static func check(
        asset: AVAsset, track: AVAssetTrack, findings: [Finding], options: SensitiveDetector.Options, thorough: Bool,
        aspect: CGFloat, frameRate: Double, every: Int, offset: Int, ranges: [ClosedRange<Double>],
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> Report {
        let reader = try AVAssetReader(asset: asset)
        let start = ranges.map(\.lowerBound).min()!, end = ranges.map(\.upperBound).max()!
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ScanError.readFailed(reader.error) }

        let detector = SensitiveDetector(options: options)
        let lock = NSLock()
        var report = Report(leaks: [], frames: [])
        let total = ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound }

        // Reading text is the slow part, so read a few frames at once, as the scan does.
        let queue = DispatchQueue(label: "Pane.LeakAudit", qos: .userInitiated, attributes: .concurrent)
        let inFlight = DispatchSemaphore(value: 3)
        let group = DispatchGroup()

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                group.wait()
                throw CancellationError()
            }
            let time = sample.presentationTimeStamp.seconds
            // Counted from the start of the video, not the range, so `offset` always picks
            // the same frames.
            let index = Int((time * frameRate).rounded())
            guard index % max(every, 1) == offset, let pixels = sample.imageBuffer,
                  ranges.contains(where: { $0.contains(time) }) else { continue }

            inFlight.wait()
            group.enter()
            queue.async {
                defer {
                    inFlight.signal()
                    group.leave()
                }
                let frame = RecordingScanner.recognize(pixels, at: time, detector: detector, thorough: thorough)
                let leaks = uncovered(in: frame, findings: findings, aspect: aspect)
                lock.withLock {
                    report.leaks += leaks
                    if !leaks.isEmpty { report.frames.append(frame) }
                }
                let done = ranges.reduce(0) { $0 + max(0, min(time, $1.upperBound) - $1.lowerBound) }
                progress(min(1, done / max(total, 0.001)))
            }
        }
        group.wait()
        if reader.status == .failed { throw ScanError.readFailed(reader.error) }

        report.leaks.sort { $0.time < $1.time }
        report.frames.sort { $0.time < $1.time }
        return report
    }

    /// The sensitive text in `frame` that the blurs don't hide.
    static func uncovered(in frame: FrameText, findings: [Finding], aspect: CGFloat) -> [Leak] {
        let covers = findings.compactMap { $0.coverRect(at: frame.time, aspect: aspect) }
        return frame.matches.compactMap { match in
            let area = match.rect.width * match.rect.height
            guard area > 0 else { return nil }
            // How much of the text the blurs cover (overlaps counted once is close
            // enough here; blurs rarely overlap each other).
            let hidden = covers.reduce(0.0) { total, cover in
                let overlap = cover.intersection(match.rect)
                return overlap.isNull ? total : total + Double(overlap.width * overlap.height / area)
            }
            guard hidden < enough else { return nil }
            return Leak(time: frame.time, text: match.text, kind: match.kind, rect: match.rect, covered: min(hidden, 1))
        }
    }
}
