import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

enum Permissions {
    enum Pane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case camera = "Privacy_Camera"
        case microphone = "Privacy_Microphone"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    static func requestCapture(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    /// Shows the system prompt the first time. CGPreflightScreenCaptureAccess can keep
    /// answering "no" after access is granted, so ScreenCaptureKit gets the final say.
    static func ensureScreenRecording() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)) != nil {
            return true
        }
        CGRequestScreenCaptureAccess()
        return false
    }

    /// Input Monitoring, which keyboard shortcut badges need. Checking never prompts.
    static var inputMonitoringAllowed: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time; later, macOS only answers.
    static func requestInputMonitoring() {
        CGRequestListenEventAccess()
    }

    /// Quits and opens a fresh copy of Pane, which macOS sometimes needs to apply a new
    /// permission.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"$0\"",
                          Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func openSettings(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }
}
