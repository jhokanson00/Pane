import Foundation

/// Cutting the start and end off a recording. The kept part is a range of seconds on
/// the recording's own timeline, so blurs, clicks and pointer effects keep their times;
/// only the output is shifted to start at zero.
public enum Trim {
    /// The shortest part that can be kept, so a trim never leaves an empty video.
    public static let minimumLength = 0.5

    /// The kept part after trimming the start at `time`.
    /// - Parameter range: The part kept so far; nil keeps the whole video.
    /// - Returns: nil when the whole video is kept again. A start past the current end
    ///   gives the end back, since the old end can't apply any more.
    public static func start(at time: Double, keeping range: ClosedRange<Double>?, duration: Double) -> ClosedRange<Double>? {
        guard duration > minimumLength else { return nil }
        let start = min(max(time, 0), duration - minimumLength)
        var end = range?.upperBound ?? duration
        if end - start < minimumLength { end = duration }
        return normalized(start...end, duration: duration)
    }

    /// The kept part after trimming the end at `time`. An end before the current start
    /// gives the start back.
    public static func end(at time: Double, keeping range: ClosedRange<Double>?, duration: Double) -> ClosedRange<Double>? {
        guard duration > minimumLength else { return nil }
        let end = max(min(time, duration), minimumLength)
        var start = range?.lowerBound ?? 0
        if end - start < minimumLength { start = 0 }
        return normalized(start...end, duration: duration)
    }

    /// The range cut to the video, or nil when it keeps all of it (or nothing useful).
    public static func normalized(_ range: ClosedRange<Double>?, duration: Double) -> ClosedRange<Double>? {
        guard let range else { return nil }
        let start = max(range.lowerBound, 0)
        let end = min(range.upperBound, duration)
        guard end - start > 0.001, start > 0.001 || end < duration - 0.001 else { return nil }
        return start...end
    }

    /// The kept part in whole frames, for Final Cut, whose edits fall on frames. Each
    /// end goes to the nearest frame, and at least one frame is kept.
    public static func frames(_ range: ClosedRange<Double>, frameRate: Int, totalFrames: Int) -> Range<Int> {
        let rate = Double(frameRate)
        let start = min(max(Int((range.lowerBound * rate).rounded()), 0), max(totalFrames - 1, 0))
        let end = min(max(Int((range.upperBound * rate).rounded()), start + 1), max(totalFrames, start + 1))
        return start..<end
    }
}
