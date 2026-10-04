import AppKit
import QuartzCore
import PaneKit

/// Logs the pointer while recording: every movement (with the mouse's own timestamps),
/// its shape (arrow or pointing hand), and every click. Nothing is drawn; effects are
/// added at export.
///
/// Movement and clicks come from a global event monitor, which needs no extra
/// permission. Events on Pane itself (like the Stop button) aren't seen, so they don't
/// show up as effects; a 60-per-second check fills in position if events go quiet.
@MainActor
final class PointerRecorder {
    enum Area {
        /// A whole display, in AppKit global coordinates.
        case display(CGRect)
        /// One window, which may move while recording.
        case window(CGWindowID, CGRect)
    }

    private struct Sample {
        var time: Double
        var point: CGPoint
        var isHand: Bool
    }

    private struct Press {
        var time: Double
        var point: CGPoint
        var button: PointerTrack.Button
        var isHand: Bool
        var released: Double?
    }

    private let area: Area
    private var samples: [Sample] = []
    private var presses: [Press] = []
    /// Where the recorded window was over time (only for window recordings).
    private var windowFrames: [(time: Double, frame: CGRect)] = []
    private var isHand = false
    private var tick = 0
    private var timer: Timer?
    private var monitor: Any?
    private var moveMonitor: Any?
    /// While paused nothing is logged; the video has no frames from then either.
    private var isPaused = false

    init(area: Area) {
        self.area = area
        if case .window(_, let frame) = area {
            windowFrames = [(CACurrentMediaTime(), frame)]
        }
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        ]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]) { [weak self] event in
            MainActor.assumeIsolated { self?.moved(event) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for case let monitor? in [monitor, moveMonitor] { NSEvent.removeMonitor(monitor) }
        monitor = nil
        moveMonitor = nil
    }

    /// Logs where the pointer is now, then nothing until `resume()`. A button still held
    /// counts as released here, so its click doesn't seem to last through the pause.
    func pause() {
        guard !isPaused else { return }
        sample()
        let now = CACurrentMediaTime()
        for index in presses.indices where presses[index].released == nil {
            presses[index].released = now
        }
        isPaused = true
    }

    /// Starts logging again, from where the pointer and window are now.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        isHand = Self.pointerIsHand()
        if case .window(let id, _) = area, let frame = Self.frame(of: id), frame != windowFrames.last?.frame {
            windowFrames.append((CACurrentMediaTime(), frame))
        }
        sample()
    }

    // MARK: - Capture

    private func sample() {
        guard !isPaused else { return }
        let now = CACurrentMediaTime()
        tick += 1
        // The pointer's shape and the window's position change rarely and cost more to
        // read, so check them less often.
        if tick % 3 == 0 { isHand = Self.pointerIsHand() }
        if tick % 6 == 0, case .window(let id, _) = area, let frame = Self.frame(of: id),
           frame != windowFrames.last?.frame {
            windowFrames.append((now, frame))
        }

        add(Sample(time: now, point: NSEvent.mouseLocation, isHand: isHand))
    }

    /// Movement events arrive at the mouse's own rate with exact timestamps, which keeps
    /// effects on the pointer even during fast flicks.
    private func moved(_ event: NSEvent) {
        guard !isPaused else { return }
        let time = eventTime(event)
        // A few hundred a second is plenty.
        if let last = samples.last, time - last.time < 0.004, time >= last.time { return }
        let point = event.window == nil ? event.locationInWindow : NSEvent.mouseLocation
        add(Sample(time: time, point: point, isHand: isHand))
    }

    private func add(_ sample: Sample) {
        // While the pointer is still, only the start and end of the stillness matter.
        if samples.count >= 2,
           samples[samples.count - 1].point == sample.point, samples[samples.count - 2].point == sample.point,
           samples[samples.count - 1].isHand == sample.isHand, samples[samples.count - 2].isHand == sample.isHand,
           sample.time >= samples[samples.count - 1].time {
            samples[samples.count - 1].time = sample.time
        } else {
            samples.append(sample)
        }
    }

    /// Event timestamps share the clock the recording uses; fall back to "now" if not.
    private func eventTime(_ event: NSEvent) -> Double {
        let now = CACurrentMediaTime()
        return abs(event.timestamp - now) < 1 ? event.timestamp : now
    }

    /// Called on every press that's logged (the teleprompter ticks off its click cues).
    var onPress: (() -> Void)?

    private func handle(_ event: NSEvent) {
        guard !isPaused else { return }
        let time = eventTime(event)
        let button: PointerTrack.Button = switch event.type {
        case .leftMouseDown, .leftMouseUp: .left
        case .rightMouseDown, .rightMouseUp: .right
        default: .other
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let point = event.window == nil ? event.locationInWindow : NSEvent.mouseLocation
            presses.append(Press(time: time, point: point, button: button, isHand: Self.pointerIsHand()))
            onPress?()
        default:
            if let index = presses.lastIndex(where: { $0.button == button && $0.released == nil }) {
                presses[index].released = time
            }
        }
    }

    /// The pointing hand that apps show over links and buttons, recognized by where its
    /// hot spot sits in the image (this holds at any pointer size).
    private static func pointerIsHand() -> Bool {
        guard let current = NSCursor.currentSystem else { return false }
        func signature(_ cursor: NSCursor) -> (CGFloat, CGFloat, CGFloat)? {
            let size = cursor.image.size
            guard size.width > 0, size.height > 0 else { return nil }
            return (cursor.hotSpot.x / size.width, cursor.hotSpot.y / size.height, size.width / size.height)
        }
        guard let a = signature(current), let b = signature(.pointingHand) else { return false }
        return abs(a.0 - b.0) < 0.05 && abs(a.1 - b.1) < 0.05 && abs(a.2 - b.2) < 0.08
    }

    private static func frame(of window: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds)
        else { return nil }
        return WindowCatalog.appKitFrame(fromCaptureFrame: rect)
    }

    // MARK: - Building the track

    /// Converts the log to the video's timeline and coordinates: one sample per video
    /// frame, placed where the pointer was when that frame's picture was captured.
    /// - Parameters:
    ///   - timeline: Each frame's time in the video and when its picture was captured.
    ///   - cameraCircle: Where the camera circle is (normalized), if there is one.
    func track(timeline: ScreenRecorder.Timeline, cameraCircle: CGRect?) -> PointerTrack {
        let raw = samples.sorted { $0.time < $1.time }
        let frames = timeline.frames

        func frame(at host: Double) -> CGRect {
            switch area {
            case .display(let frame):
                return frame
            case .window:
                return windowFrames.last { $0.time <= host }?.frame ?? windowFrames.first?.frame ?? .zero
            }
        }
        func normalized(_ point: CGPoint, at host: Double) -> CGPoint {
            let f = frame(at: host)
            guard f.width > 0, f.height > 0 else { return .zero }
            return CGPoint(x: (point.x - f.minX) / f.width, y: (point.y - f.minY) / f.height)
        }

        // Walk the frames and the log together; both are in time order.
        var index = 0
        var trackSamples: [PointerTrack.Sample] = []
        for videoFrame in frames {
            let host = videoFrame.captured
            guard !raw.isEmpty else { break }
            while index + 1 < raw.count, raw[index + 1].time <= host { index += 1 }
            let a = raw[index]
            var point = a.point
            if index + 1 < raw.count, host > a.time {
                let b = raw[index + 1]
                let t = (host - a.time) / max(b.time - a.time, 0.0001)
                point = CGPoint(x: a.point.x + (b.point.x - a.point.x) * t, y: a.point.y + (b.point.y - a.point.y) * t)
            }
            let p = normalized(point, at: host)
            let sample = PointerTrack.Sample(time: videoFrame.time, x: p.x, y: p.y, isHand: a.isHand)
            // Keep only changes, plus the end of each still stretch.
            if trackSamples.count >= 2,
               let last = trackSamples.last, last.x == sample.x, last.y == sample.y, last.isHand == sample.isHand,
               trackSamples[trackSamples.count - 2].x == sample.x, trackSamples[trackSamples.count - 2].y == sample.y,
               trackSamples[trackSamples.count - 2].isHand == sample.isHand {
                trackSamples[trackSamples.count - 1].time = sample.time
            } else {
                trackSamples.append(sample)
            }
        }

        // A click shows from the first frame whose picture was captured after it.
        let clicks: [PointerTrack.Click] = presses.compactMap { press in
            guard let shown = frames.first(where: { $0.captured >= press.time }) else { return nil }
            let p = normalized(press.point, at: press.time)
            return PointerTrack.Click(time: shown.time, x: p.x, y: p.y, button: press.button, isHand: press.isHand,
                                      duration: max(0, (press.released ?? press.time) - press.time))
        }
        return PointerTrack(samples: trackSamples, clicks: clicks,
                            pointSize: 1 / Double(max(frame(at: raw.first?.time ?? 0).height, 1)),
                            cameraCircle: cameraCircle)
    }
}
