import AppKit
import ScreenCaptureKit

/// An open window you can choose to record.
struct WindowChoice: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bundleID: String
    /// Window frame in global screen coordinates with a top-left origin (ScreenCaptureKit's).
    let frame: CGRect
    var thumbnail: CGImage?

    var displayTitle: String { title.isEmpty ? appName : title }
    var appIcon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

enum WindowCatalog {
    /// Recordable windows on the current desktop, front-most first, with thumbnails.
    /// Leaves out Pane itself and every app on the "Never record" list.
    static func load(hiddenBundleIDs: Set<String>) async throws -> [WindowChoice] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let windows = content.windows.filter { window in
            guard let app = window.owningApplication,
                  app.processID != ownPID,
                  !hiddenBundleIDs.contains(app.bundleIdentifier)
            else { return false }
            // Layer 0 is ordinary app windows (not menus, the Dock, overlays, etc.).
            return window.windowLayer == 0 && window.frame.width >= 120 && window.frame.height >= 80
        }

        var choices = windows.map { window in
            WindowChoice(
                id: window.windowID,
                title: window.title ?? "",
                appName: window.owningApplication?.applicationName ?? "",
                bundleID: window.owningApplication?.bundleIdentifier ?? "",
                frame: window.frame
            )
        }

        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, window) in windows.enumerated() {
                group.addTask { (index, try? await thumbnail(for: window)) }
            }
            for await (index, image) in group {
                choices[index].thumbnail = image
            }
        }
        return choices
    }

    static func thumbnail(for window: SCWindow) async throws -> CGImage {
        let maxSide: CGFloat = 480
        let scale = maxSide / max(window.frame.width, window.frame.height, 1)
        let config = SCStreamConfiguration()
        config.width = max(2, Int(window.frame.width * scale))
        config.height = max(2, Int(window.frame.height * scale))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: config
        )
    }

    /// Converts a ScreenCaptureKit frame (top-left origin) to AppKit coordinates
    /// (bottom-left origin of the primary display).
    static func appKitFrame(fromCaptureFrame frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
