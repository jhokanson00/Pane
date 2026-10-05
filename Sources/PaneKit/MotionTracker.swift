import AVFoundation
import CoreGraphics

/// Follows each finding on every frame of the video, so the blur moves with the text
/// as it scrolls instead of jumping between the scanner's few readings per second.
///
/// The scanner reads text about 3 times a second. Here, each finding's pixels at those
/// readings become a template that's searched for in every frame in between, and a
/// little before and after, to catch text scrolling in or out.
public enum MotionTracker {
    public static func refine(
        findings: [Finding],
        url: URL,
        interval: Double,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [Finding] {
        let tracked = findings.indices.filter { findings[$0].kind != .manual && !findings[$0].samples.isEmpty }
        guard !tracked.isEmpty else { return findings }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return findings }
        let frameRate = Double(try await track.load(.nominalFrameRate))

        return try await Task.detached(priority: .userInitiated) {
            let jobs = tracked.map { Job(finding: findings[$0], interval: interval) }
            try follow(jobs: jobs, asset: asset, track: track, duration: duration,
                       frameDuration: 1 / max(frameRate, 1), progress: progress)
            var result = findings
            for (index, job) in zip(tracked, jobs) {
                result[index] = job.refinedFinding()
            }
            return mergingDuplicates(result, frameDuration: 1 / max(frameRate, 1))
        }.value
    }

    /// The scanner sometimes reads the same text two ways (an "I" as a "1"), which
    /// makes two overlapping blurs. When one stops and the other carries on, the blur
    /// visibly jumps, so blurs that sit on the same spot at the same time become one.
    static func mergingDuplicates(_ findings: [Finding], frameDuration: Double) -> [Finding] {
        var findings = findings
        var merged = true
        while merged {
            merged = false
            search: for a in findings.indices {
                for b in findings.indices where b != a && findings[a].kind == findings[b].kind
                    && findings[a].kind != .manual && findings[a].samples.count >= findings[b].samples.count {
                    guard let combined = combine(findings[a], findings[b], frameDuration: frameDuration) else { continue }
                    findings[a] = combined
                    findings.remove(at: b)
                    merged = true
                    break search
                }
            }
        }
        return findings
    }

    /// `main` with `other`'s extra frames added, lined up to match, or nil if they
    /// aren't the same text.
    private static func combine(_ main: Finding, _ other: Finding, frameDuration: Double) -> Finding? {
        let tolerance = frameDuration / 2
        func sample(in finding: Finding, near time: Double) -> BoxSample? {
            finding.samples.first { abs($0.time - time) <= tolerance }
        }
        let shared = other.samples.compactMap { b in sample(in: main, near: b.time).map { (a: $0, b: b) } }
        guard shared.count >= 3 else { return nil }
        let overlap = shared.map { FindingTracker.iou($0.a.rect, $0.b.rect) }.reduce(0, +) / Double(shared.count)
        guard overlap > 0.5 else { return nil }

        // Shift the other finding's boxes onto the main one's, and use its size, so the
        // blur doesn't change shape where one hands over to the other.
        let shiftX = shared.map { $0.a.rect.minX - $0.b.rect.minX }.reduce(0, +) / CGFloat(shared.count)
        let shiftY = shared.map { $0.a.rect.minY - $0.b.rect.minY }.reduce(0, +) / CGFloat(shared.count)
        let size = shared.last!.a.rect.size
        var result = main
        for b in other.samples where sample(in: main, near: b.time) == nil {
            result.samples.append(BoxSample(time: b.time, rect: CGRect(
                origin: CGPoint(x: b.rect.minX + shiftX, y: b.rect.minY + shiftY), size: size)))
        }
        result.samples.sort { $0.time < $1.time }
        result.start = min(main.start, other.start)
        result.end = max(main.end, other.end)
        return result
    }

    private static func follow(
        jobs: [Job], asset: AVAsset, track: AVAssetTrack, duration: Double, frameDuration: Double,
        progress: @Sendable (Double) -> Void
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ScanError.readFailed(reader.error) }

        // Recent frames, for tracing text back to just before it was first read.
        var recent: [LumaPlane] = []
        let keepRecent = (jobs.first?.lookBack ?? 0.5) + frameDuration

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            let time = sample.presentationTimeStamp.seconds
            let live = jobs.filter { $0.needs(time, frameDuration: frameDuration) }
            guard !live.isEmpty, let pixels = sample.imageBuffer,
                  let plane = LumaPlane(pixels, time: time) else { continue }

            for job in live {
                job.step(plane, recent: recent, frameDuration: frameDuration)
            }
            recent.append(plane)
            recent.removeAll { $0.time < time - keepRecent }
            progress(min(1, time / max(duration, 0.001)))
        }
        if reader.status == .failed { throw ScanError.readFailed(reader.error) }
        progress(1)
    }
}

// MARK: - One finding

private final class Job {
    struct Point {
        var time: Double
        var origin: CGPoint
        var segment: Int
    }

    struct Anchor {
        var segment: Int
        var offset: CGPoint
        var size: CGSize
    }

    let finding: Finding
    let keys: [BoxSample]
    /// How far before the first reading to look for the text.
    let lookBack: Double
    /// How far past the last reading to keep following the text: for as long as its
    /// pixels are still there. Text reading can miss small or faint text for seconds at
    /// a time, so the blur holds until the content itself changes or moves away, not
    /// until the reader stops seeing it.
    let lookAhead = Double.infinity
    /// How long to keep moving the blur after losing the text, in case it's still there.
    let coast = 0.15

    private var nextKey = 0
    private var template: Template?
    private var origin = CGPoint.zero
    private var velocity = CGPoint.zero
    private var segment = 0
    private var lostAt: Double?
    private var isDone = false
    private var path: [Point] = []
    private var anchors: [Anchor] = []
    /// The tracking frame size, for converting boxes back to normalized ones.
    private var frame: LumaPlane?

    init(finding: Finding, interval: Double) {
        self.finding = finding
        self.keys = finding.samples
        self.lookBack = interval + 0.1
    }

    func needs(_ time: Double, frameDuration: Double) -> Bool {
        guard !isDone, let first = keys.first, let last = keys.last else { return false }
        return time >= first.time - lookBack - frameDuration && time <= last.time + lookAhead
    }

    func step(_ plane: LumaPlane, recent: [LumaPlane], frameDuration: Double) {
        if frame == nil { frame = LumaPlane(time: 0, width: plane.width, height: plane.height, pixels: []) }
        while nextKey < keys.count, keys[nextKey].time < plane.time - frameDuration / 2 {
            nextKey += 1
        }
        if nextKey < keys.count, abs(plane.time - keys[nextKey].time) <= frameDuration / 2 {
            read(keys[nextKey], in: plane, recent: recent, frameDuration: frameDuration)
            nextKey += 1
            return
        }
        guard let template else { return }
        let afterLastKey = nextKey >= keys.count

        if let lostAt {
            // Between readings, the next reading picks the text back up.
            guard afterLastKey else { return }
            // Text scrolling off the edge can't be matched once most of it is gone, but
            // what's left must stay covered, so keep it moving until it's off screen.
            let leaving = template.isPartlyOffScreen(at: origin, in: plane) && hypot(velocity.x, velocity.y) > 0.3
            if plane.time - lostAt <= coast || leaving {
                origin.x += velocity.x
                origin.y += velocity.y
                if template.isOffScreen(at: origin, in: plane) {
                    isDone = true
                } else {
                    record(plane.time)
                }
            } else {
                isDone = true
            }
            return
        }

        if let found = template.locate(in: plane, near: predicted) {
            move(to: found)
            record(plane.time)
        } else {
            lostAt = plane.time
            if afterLastKey {
                origin.x += velocity.x
                origin.y += velocity.y
                record(plane.time)
            }
        }
    }

    /// A frame the scanner read: where the text is for certain.
    private func read(_ key: BoxSample, in plane: LumaPlane, recent: [LumaPlane], frameDuration: Double) {
        let rect = plane.pixelRect(key.rect)
        let patch = Template.patchRect(around: rect, in: plane)

        if let template, lostAt == nil, let found = template.locate(in: plane, near: predicted),
           hypot(found.x - patch.minX, found.y - patch.minY) < max(rect.height * 0.5, 2) {
            // Still on the same text; keep the motion smooth.
            move(to: found)
        } else {
            let isFirst = template == nil
            if !isFirst { segment += 1 }
            template = Template(plane, rect: patch)
            // The speed since the text was last seen, not whatever it was doing before it
            // was lost.
            if let last = path.last, plane.time > last.time {
                let frames = CGFloat(max((plane.time - last.time) / frameDuration, 1))
                velocity = CGPoint(x: (patch.minX - last.origin.x) / frames, y: (patch.minY - last.origin.y) / frames)
            } else {
                velocity = .zero
            }
            origin = patch.origin
            lostAt = nil
            record(plane.time)
            anchors.append(Anchor(segment: segment, offset: CGPoint(x: rect.minX - origin.x, y: rect.minY - origin.y),
                                  size: rect.size))
            if isFirst { traceBack(from: plane.time, through: recent) }
            return
        }
        record(plane.time)
        anchors.append(Anchor(segment: segment, offset: CGPoint(x: rect.minX - origin.x, y: rect.minY - origin.y),
                              size: rect.size))
    }

    /// Follows the text backward to where it was just before the first reading.
    private func traceBack(from time: Double, through recent: [LumaPlane]) {
        guard let template else { return }
        var position = origin
        var drift = CGPoint.zero
        var earlier: [Point] = []
        var lost = false
        for plane in recent.reversed() where plane.time < time && plane.time >= time - lookBack {
            let guess = CGPoint(x: position.x + drift.x, y: position.y + drift.y)
            if !lost, let found = template.locate(in: plane, near: guess) {
                drift = CGPoint(x: found.x - position.x, y: found.y - position.y)
                position = found
            } else if template.isPartlyOffScreen(at: position, in: plane) {
                // Scrolling in from the edge: keep covering the part already showing.
                lost = true
                position = guess
                if template.isOffScreen(at: position, in: plane) { break }
            } else {
                break
            }
            earlier.append(Point(time: plane.time, origin: position, segment: segment))
        }
        path.insert(contentsOf: earlier.reversed(), at: 0)
    }

    private var predicted: CGPoint {
        CGPoint(x: origin.x + velocity.x, y: origin.y + velocity.y)
    }

    private func move(to found: CGPoint) {
        let step = CGPoint(x: found.x - origin.x, y: found.y - origin.y)
        velocity = CGPoint(x: velocity.x * 0.5 + step.x * 0.5, y: velocity.y * 0.5 + step.y * 0.5)
        origin = found
    }

    private func record(_ time: Double) {
        path.append(Point(time: time, origin: origin, segment: segment))
    }

    /// The finding with a box for every frame it was followed through.
    func refinedFinding() -> Finding {
        guard !path.isEmpty, !anchors.isEmpty, let plane = frame else { return finding }

        // Each reading measures the box a little differently. One size for the whole
        // finding keeps the blur from changing shape: big enough for nearly all its
        // readings (mid-scroll readings can come out short), but not for the odd one
        // that took in part of the line above. The middle of each run's centers keeps it
        // steady instead of twitching at every reading.
        func largest(_ values: [CGFloat]) -> CGFloat {
            let sorted = values.sorted()
            return min(sorted[Int(Double(sorted.count - 1) * 0.9)], median(values) * 1.5)
        }
        let size = CGSize(width: largest(anchors.map(\.size.width)), height: largest(anchors.map(\.size.height)))
        var placement: [Int: (offset: CGPoint, size: CGSize)] = [:]
        for run in Set(anchors.map(\.segment)) {
            let group = anchors.filter { $0.segment == run }
            let center = CGPoint(x: median(group.map { $0.offset.x + $0.size.width / 2 }),
                                 y: median(group.map { $0.offset.y + $0.size.height / 2 }))
            placement[run] = (CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), size)
        }

        var samples: [BoxSample] = path.compactMap { point in
            guard let place = placement[point.segment] else { return nil }
            let rect = CGRect(x: point.origin.x + place.offset.x, y: point.origin.y + place.offset.y,
                              width: place.size.width, height: place.size.height)
            return BoxSample(time: point.time, rect: plane.normalizedRect(rect))
        }
        // Readings where the text couldn't be followed still count.
        let followed = samples.map(\.time)
        for key in keys where !followed.contains(where: { abs($0 - key.time) < 0.001 }) {
            samples.append(key)
        }
        samples.sort { $0.time < $1.time }

        var refined = finding
        refined.samples = samples
        refined.start = samples.first!.time
        refined.end = samples.last!.time
        return refined
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

// MARK: - Pixels

/// A frame's brightness, scaled down so tracking stays fast on large recordings.
struct LumaPlane {
    let time: Double
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(time: Double, width: Int, height: Int, pixels: [UInt8]) {
        self.time = time
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(_ buffer: CVPixelBuffer, time: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferIsPlanar(buffer), let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let source = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let fullWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let fullHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)

        // Text stays several pixels tall at this size, which is plenty to match on.
        let factor = max(1, Int((Double(fullHeight) / 900).rounded(.up)))
        let width = fullWidth / factor
        let height = fullHeight / factor
        let area = factor * factor
        let pixels = [UInt8](unsafeUninitializedCapacity: width * height) { out, count in
            for y in 0..<height {
                for x in 0..<width {
                    var sum = 0
                    for dy in 0..<factor {
                        let row = source + (y * factor + dy) * bytesPerRow + x * factor
                        for dx in 0..<factor { sum += Int(row[dx]) }
                    }
                    out[y * width + x] = UInt8(sum / area)
                }
            }
            count = width * height
        }
        self.init(time: time, width: width, height: height, pixels: pixels)
    }

    /// Half the size, for searching wide areas quickly.
    func halved() -> LumaPlane {
        let w = width / 2, h = height / 2
        let pixels = [UInt8](unsafeUninitializedCapacity: w * h) { out, count in
            self.pixels.withUnsafeBufferPointer { p in
                for y in 0..<h {
                    for x in 0..<w {
                        let i = 2 * y * width + 2 * x
                        out[y * w + x] = UInt8((Int(p[i]) + Int(p[i + 1]) + Int(p[i + width]) + Int(p[i + width + 1])) / 4)
                    }
                }
            }
            count = w * h
        }
        return LumaPlane(time: time, width: w, height: h, pixels: pixels)
    }

    /// Normalized bottom-left rect to this plane's pixels, top-left origin.
    func pixelRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * CGFloat(width), y: (1 - rect.maxY) * CGFloat(height),
               width: rect.width * CGFloat(width), height: rect.height * CGFloat(height))
    }

    func normalizedRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX / CGFloat(width), y: 1 - rect.maxY / CGFloat(height),
               width: rect.width / CGFloat(width), height: rect.height / CGFloat(height))
    }
}

/// The pixels around a finding at one moment, and the search for them in other frames.
struct Template {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    /// How much ink there is on average, so "a good match" scales with how busy the text is.
    let contrast: Double
    /// Running total of each row's ink (difference from the average brightness), so a
    /// match that's partly off screen can be required to still show most of the text.
    private let ink: [Double]
    private let coarse: (width: Int, height: Int, pixels: [UInt8], ink: [Double])

    /// The text plus a little of what's around it, which makes the match more certain.
    static func patchRect(around rect: CGRect, in plane: LumaPlane) -> CGRect {
        rect.insetBy(dx: -rect.height * 0.3, dy: -rect.height * 0.25).integral
            .intersection(CGRect(x: 0, y: 0, width: plane.width, height: plane.height))
    }

    init(_ plane: LumaPlane, rect: CGRect) {
        let x0 = Int(rect.minX), y0 = Int(rect.minY)
        width = max(1, Int(rect.width))
        height = max(1, Int(rect.height))
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let sx = min(max(x0 + x, 0), plane.width - 1)
                let sy = min(max(y0 + y, 0), plane.height - 1)
                pixels[y * width + x] = plane.pixels[sy * plane.width + sx]
            }
        }
        self.pixels = pixels
        ink = Self.rowInk(pixels, width: width, height: height)
        contrast = ink[height] / Double(pixels.count)

        let cw = max(1, width / 2), ch = max(1, height / 2)
        var small = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw {
                let i = min(2 * y, height - 1) * width + min(2 * x, width - 1)
                let r = min(i + width, pixels.count - 1)
                small[y * cw + x] = UInt8((Int(pixels[i]) + Int(pixels[min(i + 1, pixels.count - 1)])
                                           + Int(pixels[r]) + Int(pixels[min(r + 1, pixels.count - 1)])) / 4)
            }
        }
        coarse = (cw, ch, small, Self.rowInk(small, width: cw, height: ch))
    }

    /// Ink is how far each pixel is from the background (the most common brightness), so
    /// empty background counts as none.
    private static func rowInk(_ pixels: [UInt8], width: Int, height: Int) -> [Double] {
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels { histogram[Int(value)] += 1 }
        let background = Double(histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0)
        var totals = [0.0]
        for y in 0..<height {
            let row = pixels[(y * width)..<((y + 1) * width)].reduce(0.0) { $0 + abs(Double($1) - background) }
            totals.append(totals[y] + row)
        }
        return totals
    }

    /// Scores are relative to the text's own contrast; 0 is a perfect match.
    private var goodEnough: Double { max(5 / max(contrast, 1), 0.4) }

    func isPartlyOffScreen(at origin: CGPoint, in plane: LumaPlane) -> Bool {
        origin.x < 0 || origin.y < 0
            || origin.x + CGFloat(width) > CGFloat(plane.width) || origin.y + CGFloat(height) > CGFloat(plane.height)
    }

    func isOffScreen(at origin: CGPoint, in plane: LumaPlane) -> Bool {
        origin.x + CGFloat(width) <= 0 || origin.y + CGFloat(height) <= 0
            || origin.x >= CGFloat(plane.width) || origin.y >= CGFloat(plane.height)
    }

    /// Where this template's top-left corner is in `plane`, to a fraction of a pixel,
    /// or nil if it isn't there.
    func locate(in plane: LumaPlane, near guess: CGPoint) -> CGPoint? {
        let gx = Int(guess.x.rounded()), gy = Int(guess.y.rounded())

        // Usually the text is right where it was heading.
        var best = (x: gx, y: gy, score: Double.infinity)
        for dy in -3...3 {
            for dx in -3...3 {
                if let s = score(plane, x: gx + dx, y: gy + dy, bound: best.score), s < best.score {
                    best = (gx + dx, gy + dy, s)
                }
            }
        }
        let onEdge = abs(best.x - gx) == 3 || abs(best.y - gy) == 3
        if best.score > goodEnough || onEdge {
            // It moved unexpectedly (a fast flick); search a wider area at half size.
            let small = plane.halved()
            let rangeY = 90, rangeX = 50
            var wide = (x: gx / 2, y: gy / 2, score: Double.infinity)
            for dy in -rangeY...rangeY {
                for dx in -rangeX...rangeX {
                    let x = gx / 2 + dx, y = gy / 2 + dy
                    if let s = coarseScore(small, x: x, y: y, bound: wide.score), s < wide.score {
                        wide = (x, y, s)
                    }
                }
            }
            for dy in -2...2 {
                for dx in -2...2 {
                    let x = wide.x * 2 + dx, y = wide.y * 2 + dy
                    if let s = score(plane, x: x, y: y, bound: best.score), s < best.score {
                        best = (x, y, s)
                    }
                }
            }
        }
        guard best.score <= goodEnough else { return nil }

        // Fit a curve through the neighbors for a sub-pixel position, so slow scrolls
        // move the blur smoothly instead of a pixel at a time.
        func refine(_ minus: Double?, _ plus: Double?) -> CGFloat {
            guard let minus, let plus else { return 0 }
            let denominator = minus - 2 * best.score + plus
            guard denominator > 0.0001 else { return 0 }
            return CGFloat(min(0.5, max(-0.5, (minus - plus) / (2 * denominator))))
        }
        let fx = refine(score(plane, x: best.x - 1, y: best.y), score(plane, x: best.x + 1, y: best.y))
        let fy = refine(score(plane, x: best.x, y: best.y - 1), score(plane, x: best.x, y: best.y + 1))
        return CGPoint(x: CGFloat(best.x) + fx, y: CGFloat(best.y) + fy)
    }

    /// Average brightness difference with the template's corner at (x, y), relative to the
    /// template's contrast, or nil if too little of it is on screen. Stops early once it
    /// can't beat `bound`.
    private func score(_ plane: LumaPlane, x: Int, y: Int, bound: Double = .infinity) -> Double? {
        Self.compare(pixels, width: width, height: height, ink: ink, plane, x: x, y: y, bound: bound)
    }

    private func coarseScore(_ plane: LumaPlane, x: Int, y: Int, bound: Double) -> Double? {
        Self.compare(coarse.pixels, width: coarse.width, height: coarse.height, ink: coarse.ink,
                     plane, x: x, y: y, bound: bound)
    }

    private static func compare(_ template: [UInt8], width: Int, height: Int, ink: [Double], _ plane: LumaPlane,
                                x: Int, y: Int, bound: Double) -> Double? {
        let tx0 = max(0, -x), tx1 = min(width, plane.width - x)
        let ty0 = max(0, -y), ty1 = min(height, plane.height - y)
        guard tx1 > tx0, ty1 > ty0 else { return nil }
        let count = (tx1 - tx0) * (ty1 - ty0)
        // Partly off screen is fine, as long as most of the text itself is still visible;
        // plain background alone matches anything.
        let visible = (ink[ty1] - ink[ty0]) * Double(tx1 - tx0) / Double(width)
        guard visible >= ink[height] * 0.35, visible > 0 else { return nil }
        // Scored against how much detail the visible part has, so a sliver of text at the
        // edge has to match as closely as the whole thing would.
        let scale = visible / Double(count)
        let limit = bound.isFinite ? Int(bound * scale * Double(count)) : Int.max

        return template.withUnsafeBufferPointer { t in
            plane.pixels.withUnsafeBufferPointer { p in
                var sum = 0
                for ty in ty0..<ty1 {
                    let tRow = ty * width
                    let pRow = (y + ty) * plane.width + x
                    for tx in tx0..<tx1 {
                        let d = Int(t[tRow + tx]) - Int(p[pRow + tx])
                        sum += d < 0 ? -d : d
                    }
                    if sum > limit { return nil }
                }
                return Double(sum) / Double(count) / scale
            }
        }
    }
}
