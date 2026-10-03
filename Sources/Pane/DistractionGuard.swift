import AppKit
import ScreenCaptureKit
import PaneKit

/// Keeps a full-screen recording free of distractions: Pane itself, the "Never record"
/// apps, notification banners, and the desktop icons when "Hide desktop icons" is on.
/// Which windows go is decided by `CaptureExclusion`.
///
/// Banners are windows that can appear mid-recording, and a filter only knows the apps
/// and windows that existed when it was made. So while recording, the filter is rebuilt
/// every half second, and sooner when a left-out app (Finder, with the icons hidden)
/// opens or closes a window. That check asks the window server for window owners and
/// levels only, which takes a few milliseconds and needs no extra permission. The stream
/// only gets a new filter when it would leave out something different.
final class DistractionGuard: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let neverRecord: Set<String>
    let hideDesktopIcons: Bool
    /// Only touched on the main thread.
    private var task: Task<Void, Never>?
    /// What the filter the recording starts with leaves out.
    private var initial: Exclusion?

    init(displayID: CGDirectDisplayID, neverRecord: Set<String>, hideDesktopIcons: Bool) {
        self.displayID = displayID
        self.neverRecord = neverRecord
        self.hideDesktopIcons = hideDesktopIcons
    }

    /// What a filter leaves out, to tell whether a new one would change anything.
    private struct Exclusion: Equatable {
        var apps: Set<pid_t>
        var keptWindows: Set<CGWindowID>
    }

    /// The display minus everything left out, as of `content`.
    func filter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let (filter, exclusion) = makeFilter(display: display, content: content)
        initial = exclusion
        return filter
    }

    private func makeFilter(display: SCDisplay, content: SCShareableContent)
        -> (filter: SCContentFilter, exclusion: Exclusion) {
        let windows = content.windows.map {
            CaptureExclusion.Window(id: $0.windowID, bundleID: $0.owningApplication?.bundleIdentifier,
                                    layer: $0.windowLayer)
        }
        let plan = CaptureExclusion.plan(windows: windows, neverRecord: neverRecord,
                                         hideDesktopIcons: hideDesktopIcons)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = content.applications.filter {
            $0.processID == ownPID || plan.excludedBundleIDs.contains($0.bundleIdentifier)
        }
        let kept = content.windows.filter { plan.keptWindowIDs.contains($0.windowID) }
        return (SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: kept),
                Exclusion(apps: Set(apps.map(\.processID)), keptWindows: Set(kept.map(\.windowID))))
    }

    /// Keeps `recorder`'s filter up to date until `stop()`.
    func start(updating recorder: ScreenRecorder) {
        task?.cancel()
        let initial = initial
        task = Task.detached(priority: .utility) { [self] in
            await watch(recorder, applied: initial)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func watch(_ recorder: ScreenRecorder, applied: Exclusion?) async {
        let leftOut = CaptureExclusion.plan(windows: [], neverRecord: neverRecord, hideDesktopIcons: hideDesktopIcons)
        var applied = applied
        var watched = CaptureExclusion.watchedWindowIDs(Self.onScreenWindows(), plan: leftOut)
        var lastRead = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            let nowWatched = CaptureExclusion.watchedWindowIDs(Self.onScreenWindows(), plan: leftOut)
            guard nowWatched != watched || lastRead.duration(to: .now) >= .milliseconds(500) else { continue }
            watched = nowWatched
            lastRead = .now

            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { continue }
            let (filter, exclusion) = makeFilter(display: display, content: content)
            guard exclusion != applied, !Task.isCancelled else { continue }
            if (try? await recorder.update(filter: filter)) != nil {
                applied = exclusion
            }
        }
    }

    /// On-screen windows with their owner and level, straight from the window server.
    private static func onScreenWindows() -> [CaptureExclusion.Window] {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var bundleIDs: [pid_t: String?] = [:]
        return entries.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t
            else { return nil }
            if bundleIDs[pid] == nil {
                bundleIDs[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
            return CaptureExclusion.Window(id: CGWindowID(number), bundleID: bundleIDs[pid] ?? nil,
                                           layer: entry[kCGWindowLayer as String] as? Int ?? 0)
        }
    }
}
