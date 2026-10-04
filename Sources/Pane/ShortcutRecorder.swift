import AppKit
import QuartzCore
import SwiftUI
import PaneKit

/// Logs keyboard shortcuts while recording, for badges at export. Nothing is drawn on
/// the recording itself.
///
/// Privacy comes first: a listen-only event tap sees every key press, but only shortcuts
/// (Command or Control held) and keys that never type (Esc, Return, Tab, Delete, arrows,
/// F-keys) are kept; see `KeyShortcut.shouldLog`. Each press is checked before even its
/// characters are read, so ordinary typing, like passwords and messages, never reaches
/// the log. macOS also hides key presses from taps while a password field has focus.
///
/// Needs Input Monitoring access. This never asks for it; turning the setting on does.
@MainActor
final class ShortcutRecorder {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var presses: [(time: Double, shortcut: KeyShortcut)] = []
    /// While paused nothing is logged; the video has no frames from then either, so a
    /// shortcut pressed then would show up the moment recording resumes.
    private var isPaused = false

    /// Starts listening. False without Input Monitoring access, or if macOS refused the tap.
    func start() -> Bool {
        guard Permissions.inputMonitoringAllowed else { return false }
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            // Key downs only: no key ups, and no modifier changes on their own.
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: shortcutTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    func pause() { isPaused = true }

    func resume() { isPaused = false }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            // Shortcuts in Pane itself, like ⌘P for Pause, aren't part of the recording
            // (its windows are left out of it), just as clicks on Pane aren't logged.
            guard !isPaused, !NSApp.isActive else { return }
            // Holding a key repeats it; only the first press counts.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            guard !PrompterHotKeys.matches(keyCode: code, flags: event.flags) else { return }
            let nsEvent = NSEvent(cgEvent: event)
            // The filter runs first; the characters are only read for a shortcut.
            guard let shortcut = KeyShortcut.logged(keyCode: code, modifiers: KeyModifiers(event.flags), characters: {
                nsEvent?.characters(byApplyingModifiers: [])
            }) else { return }
            // Event timestamps share the clock the recording uses; fall back to "now" if not.
            let now = CACurrentMediaTime()
            let time = nsEvent.map { abs($0.timestamp - now) < 1 ? $0.timestamp : now } ?? now
            presses.append((time, shortcut))
        default:
            break
        }
    }

    /// Converts the log to the video's timeline, the way clicks are: a shortcut shows
    /// from the first frame whose picture was captured after it.
    func track(timeline: ScreenRecorder.Timeline, cameraCircle: CGRect?) -> ShortcutTrack {
        let frames = timeline.frames
        let mapped = presses.compactMap { press in
            frames.first { $0.captured >= press.time }.map { ShortcutTrack.Press(time: $0.time, shortcut: press.shortcut) }
        }
        return ShortcutTrack(presses: mapped, cameraCircle: cameraCircle)
    }
}

/// The tap's callback runs on the main run loop, where its source was added.
private func shortcutTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let recorder = Unmanaged<ShortcutRecorder>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated { recorder.handle(type, event) }
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Recording

extension RecorderModel {
    /// Starts logging shortcuts if they're wanted. Without Input Monitoring the recording
    /// goes ahead without them, and Pane says why.
    func startShortcuts() {
        refreshInputMonitoring()
        guard showShortcuts else { return }
        let recorder = ShortcutRecorder()
        if recorder.start() {
            shortcutRecorder = recorder
        } else {
            Permissions.requestInputMonitoring()
            problem = .permission(.inputMonitoring, "Keyboard shortcuts aren't being recorded. Pane needs Input "
                                  + "Monitoring access: turn it on in System Settings, then quit and reopen Pane.")
        }
    }

    /// Input Monitoring can be turned on or off in System Settings at any time.
    func refreshInputMonitoring() {
        let allowed = Permissions.inputMonitoringAllowed
        if inputMonitoringAllowed != allowed { inputMonitoringAllowed = allowed }
    }

    /// Turning the setting on is the user asking, so that's when macOS shows its prompt.
    func showShortcutsChanged() {
        if showShortcuts, !Permissions.inputMonitoringAllowed { Permissions.requestInputMonitoring() }
        refreshInputMonitoring()
    }
}

extension ShortcutBadgeRenderer {
    /// Whether Review's "Show keyboard shortcuts" is on (it's remembered, and on unless
    /// turned off).
    static var shownInExports: Bool {
        get { UserDefaults.standard.object(forKey: "shortcutBadges") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "shortcutBadges") }
    }

    /// The badges for a recording, if it has shortcuts and they're shown.
    static func saved(for url: URL, videoSize: CGSize) -> ShortcutBadgeRenderer? {
        guard shownInExports, let track = ShortcutTrack.load(from: url) else { return nil }
        return ShortcutBadgeRenderer(track: track, videoSize: videoSize)
    }
}

// MARK: - Settings

/// "Show keyboard shortcuts" in the main window, with a note when macOS hasn't allowed it.
struct ShortcutSetting: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        Toggle(isOn: $model.showShortcuts) {
            VStack(alignment: .leading) {
                Text("Show keyboard shortcuts")
                Text(model.showShortcuts
                     ? "Shortcuts like ⇧⌘R show as badges in exports. Ordinary typing is never recorded."
                     : "Off. Turn on to show the shortcuts you press as badges in exports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshInputMonitoring()
        }

        if model.showShortcuts, !model.inputMonitoringAllowed {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pane needs Input Monitoring access to see shortcuts. Until it's on, recordings are made "
                     + "without them. After turning it on, quit and reopen Pane.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open System Settings") { Permissions.openSettings(.inputMonitoring) }
                    Button("Quit & Reopen Pane") { Permissions.relaunch() }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Review

/// The on/off switch for shortcut badges in the review window's Pointer tab.
struct ShortcutBadgeToggle: View {
    @ObservedObject var session: ReviewSession

    var body: some View {
        if let shortcuts = session.shortcuts {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Show keyboard shortcuts", isOn: $session.showShortcuts)
                Text(shortcuts.presses.isEmpty
                     ? "No shortcuts were pressed in this recording."
                     : "\(shortcuts.presses.count) shortcut\(shortcuts.presses.count == 1 ? "" : "s"), "
                        + "shown as badges at the bottom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .padding([.horizontal, .bottom], 12)
        }
    }
}
