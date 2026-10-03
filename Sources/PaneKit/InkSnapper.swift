import CoreGraphics
import CoreVideo

/// Tightens a text box to where the text actually is, by finding the gaps between words
/// in the frame's pixels. Vision's boxes are often loose by a character or so, which
/// makes blurs spill onto neighboring words.
struct InkSnapper {
    private let luma: UnsafePointer<UInt8>
    private let bytesPerRow: Int
    private let width: Int
    private let height: Int

    /// Runs `body` with a snapper over the brightness plane of a 4:2:0 or BGRA frame.
    static func with<T>(_ pixels: CVPixelBuffer, _ body: (InkSnapper?) -> T) -> T {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(pixels)
        let isPlanar = CVPixelBufferIsPlanar(pixels)
        guard isPlanar,
              format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)
        else { return body(nil) }

        return body(InkSnapper(
            luma: base.assumingMemoryBound(to: UInt8.self),
            bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0),
            width: CVPixelBufferGetWidthOfPlane(pixels, 0),
            height: CVPixelBufferGetHeightOfPlane(pixels, 0)
        ))
    }

    /// - Parameter rect: Normalized, bottom-left origin.
    /// - Parameters snapLeft/snapRight: Only snap edges that sit on a word boundary.
    func snap(_ rect: CGRect, snapLeft: Bool = true, snapRight: Bool = true) -> CGRect {
        let W = CGFloat(width), H = CGFloat(height)
        let textHeight = rect.height * H
        guard textHeight >= 3 else { return rect }

        let top = clamp(Int((1 - rect.maxY) * H), 0, height - 1)
        let bottom = clamp(Int((1 - rect.minY) * H), top + 1, height)
        let reach = textHeight * 1.2
        let searchStart = clamp(Int(rect.minX * W - reach), 0, width - 1)
        let searchEnd = clamp(Int(rect.maxX * W + reach), searchStart + 1, width)

        // The background is the most common brightness in the area.
        var histogram = [Int](repeating: 0, count: 256)
        for row in stride(from: top, to: bottom, by: 2) {
            let line = luma + row * bytesPerRow
            for column in stride(from: searchStart, to: searchEnd, by: 2) {
                histogram[Int(line[column])] += 1
            }
        }
        let background = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 255

        // Ink differs clearly from the background. Faint text (gray on dark gray) can
        // be barely 40 levels off, so "clearly" is measured against the strongest ink
        // here, not a fixed amount.
        var strongest = 0
        for row in top..<bottom {
            for column in Int(rect.minX * W)..<max(Int(rect.minX * W) + 1, min(Int(rect.maxX * W), width)) {
                strongest = max(strongest, abs(Int(luma[row * bytesPerRow + column]) - background))
            }
        }
        let threshold = max(14, min(48, strongest / 2))
        guard strongest >= 20 else { return rect }

        // A column has ink if any pixel in it differs clearly from the background.
        var ink = [Bool](repeating: false, count: searchEnd - searchStart)
        for column in searchStart..<searchEnd {
            for row in top..<bottom where abs(Int(luma[row * bytesPerRow + column]) - background) > threshold {
                ink[column - searchStart] = true
                break
            }
        }

        // Gaps at least ~a space wide; letter spacing is much narrower.
        let minGap = max(2, Int(textHeight * 0.18))
        var gaps: [Range<Int>] = []
        var runStart: Int?
        for (index, hasInk) in ink.enumerated() {
            if !hasInk {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                if index - start >= minGap { gaps.append(start..<index) }
                runStart = nil
            }
        }
        if let start = runStart, ink.count - start >= minGap { gaps.append(start..<ink.count) }

        var left = rect.minX * W
        var right = rect.maxX * W
        let maxShift = textHeight * 1.0
        if snapLeft {
            // The first ink after the gap nearest the estimated left edge.
            let target = left - CGFloat(searchStart)
            if let gap = gaps.filter({ $0.upperBound < ink.count })
                .min(by: { abs(CGFloat($0.upperBound) - target) < abs(CGFloat($1.upperBound) - target) }),
               abs(CGFloat(gap.upperBound) - target) <= maxShift {
                left = CGFloat(searchStart + gap.upperBound)
            }
        }
        if snapRight {
            let target = right - CGFloat(searchStart)
            if let gap = gaps.filter({ $0.lowerBound > 0 })
                .min(by: { abs(CGFloat($0.lowerBound) - target) < abs(CGFloat($1.lowerBound) - target) }),
               abs(CGFloat(gap.lowerBound) - target) <= maxShift {
                right = CGFloat(searchStart + gap.lowerBound)
            }
        }
        guard right > left else { return rect }
        let (inkTop, inkBottom) = verticalInk(top: top, bottom: bottom, left: Int(left), right: Int(right),
                                              background: background, threshold: threshold, textHeight: textHeight)
        return CGRect(x: left / W, y: 1 - CGFloat(inkBottom) / H,
                      width: (right - left) / W, height: CGFloat(inkBottom - inkTop) / H)
    }

    /// The rows the line's ink really spans, never less than Vision's box. Vision's box
    /// for small text can sit on the lowercase letters and miss the tops of b, d, h and
    /// t, which then peek out above the blur. Grows a row at a time while the next row
    /// still has ink, so it stops at the blank space between lines.
    private func verticalInk(top: Int, bottom: Int, left: Int, right: Int, background: Int, threshold: Int,
                             textHeight: CGFloat) -> (top: Int, bottom: Int) {
        let columns = clamp(left, 0, width - 1)..<clamp(right, left + 1, width)
        func hasInk(_ row: Int) -> Bool {
            guard row >= 0, row < height else { return false }
            let line = luma + row * bytesPerRow
            var count = 0
            for column in columns where abs(Int(line[column]) - background) > threshold {
                count += 1
                if count >= 2 { return true }
            }
            return false
        }
        let reach = Int((textHeight * 0.7).rounded(.up))
        var newTop = top
        while newTop > top - reach, hasInk(newTop - 1) { newTop -= 1 }
        var newBottom = bottom
        while newBottom < bottom + reach, hasInk(newBottom) { newBottom += 1 }
        return (newTop, newBottom)
    }

    private func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }
}
