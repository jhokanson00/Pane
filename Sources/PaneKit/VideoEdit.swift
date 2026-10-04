import CoreMedia
import Foundation

/// What's kept of a recording: an optional trim of the start and end, and any cuts from
/// the middle (retakes, silences), all in seconds of the recording's own timeline. Blurs,
/// clicks and pointer effects keep their recording times; only the copy closes the gaps.
public struct VideoEdit: Equatable, Sendable {
    /// Cuts shorter than this (about a frame) are left out: they'd only make a stutter.
    public static let shortestCut = 1.0 / 60

    public var trim: ClosedRange<Double>?
    public var cuts: [ClosedRange<Double>]

    public init(trim: ClosedRange<Double>? = nil, cuts: [ClosedRange<Double>] = []) {
        self.trim = trim
        self.cuts = cuts
    }

    /// The parts kept, in order, none overlapping.
    public func kept(duration: Double) -> [ClosedRange<Double>] {
        let span = Trim.normalized(trim, duration: duration) ?? 0...max(duration, 0)
        var parts: [ClosedRange<Double>] = []
        var start = span.lowerBound
        for cut in Self.merged(cuts) where cut.upperBound - cut.lowerBound >= Self.shortestCut
            && cut.upperBound > start && cut.lowerBound < span.upperBound {
            if cut.lowerBound - start > Self.shortestCut { parts.append(start...cut.lowerBound) }
            start = max(start, cut.upperBound)
        }
        if span.upperBound - start > Self.shortestCut || parts.isEmpty {
            parts.append(min(start, span.upperBound)...span.upperBound)
        }
        return parts
    }

    /// From the start of the first kept part to the end of the last: what the reader of an
    /// export has to read.
    public func span(duration: Double) -> ClosedRange<Double> {
        let parts = kept(duration: duration)
        return parts.first!.lowerBound...parts.last!.upperBound
    }

    /// Whether the copy keeps everything.
    public func keepsAll(duration: Double) -> Bool {
        let parts = kept(duration: duration)
        return parts.count == 1 && parts[0].lowerBound <= 0.001 && parts[0].upperBound >= duration - 0.001
    }

    /// How long the copy is.
    public func outputDuration(duration: Double) -> Double {
        kept(duration: duration).reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// Where a moment of the recording lands in the copy, or nil if it was cut.
    public func outputTime(_ time: Double, duration: Double) -> Double? {
        var before = 0.0
        for part in kept(duration: duration) {
            if part.contains(time) { return before + time - part.lowerBound }
            before += part.upperBound - part.lowerBound
        }
        return nil
    }

    /// The moment of the recording shown at `time` in the copy.
    public func sourceTime(_ time: Double, duration: Double) -> Double {
        var remaining = max(0, time)
        let parts = kept(duration: duration)
        for part in parts {
            let length = part.upperBound - part.lowerBound
            if remaining <= length { return part.lowerBound + remaining }
            remaining -= length
        }
        return parts.last?.upperBound ?? 0
    }

    /// The gaps between kept parts as pauses on the recording's timeline, so the same
    /// retiming that closes recording pauses closes them (see `PausedAudio`).
    public func gaps(duration: Double) -> RecordingPauses {
        var pauses = RecordingPauses()
        let parts = kept(duration: duration)
        for (left, right) in zip(parts, parts.dropFirst()) {
            _ = pauses.pause(at: left.upperBound)
            _ = pauses.resume(at: right.lowerBound)
        }
        return pauses
    }

    /// Cuts sorted, with overlapping and touching ones joined.
    static func merged(_ cuts: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for cut in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) where cut.upperBound > cut.lowerBound {
            if let last = result.last, cut.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, cut.upperBound)
            } else {
                result.append(cut)
            }
        }
        return result
    }
}
