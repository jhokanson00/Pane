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

    private static var isRelaunching = false

    /// Quits and opens a fresh copy of Pane, which macOS sometimes needs to apply a new
    /// permission.
    @MainActor
    static func relaunch() {
        // Never while recording or saving.
        guard !isRelaunching, RecorderModel.shared.state == .idle else { return }
        isRelaunching = true
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"$0\"",
                          Bundle.main.bundlePath]
        try? task.run()
        // macOS won't quit an app with a sheet open (the window picker offers this button),
        // so close sheets first.
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
        // If something still holds the quit up, leave anyway: Pane is idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }

    static func openSettings(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }
}
