import CoreGraphics

/// What a full-screen recording leaves out besides Pane itself: apps on the "Never
/// record" list, notification banners, and, when asked, the desktop icons.
///
/// A display filter can leave out whole apps and then let some of their windows back in,
/// but it can't leave out one window of an app it records. So the desktop icons are left
/// out by leaving out Finder and letting its other windows back in.
///
/// Leaving out an app is matched by its process, so it should also cover windows it opens
/// later, like a new banner. Apple doesn't document that, and it can't cover an app that
/// starts after the filter was made, or let a Finder window that opens later back in. So
/// the recorder rebuilds the filter while recording (see DistractionGuard).
public enum CaptureExclusion {
    /// Notification Center draws the banners. On macOS 26 and 27 it also owns the
    /// desktop widgets, and keeps a full-screen window above normal windows for banners.
    public static let notificationCenterBundleID = "com.apple.notificationcenterui"
    /// Finder draws the desktop icons in their own windows, one per display.
    public static let finderBundleID = "com.apple.finder"

    /// The level of Finder's desktop-icon windows: -2147483603 on macOS 26 and 27. The
    /// wallpaper is a different app's window, below this level.
    public static var desktopIconLevel: Int { Int(CGWindowLevelForKey(.desktopIconWindow)) }

    /// The little a filter needs to know about a window.
    public struct Window: Equatable, Sendable {
        public var id: UInt32
        public var bundleID: String?
        /// Window level. Normal app windows are at 0; the desktop is far below.
        public var layer: Int

        public init(id: UInt32, bundleID: String?, layer: Int) {
            self.id = id
            self.bundleID = bundleID
            self.layer = layer
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Apps left out whole, including windows they open later.
        public var excludedBundleIDs: Set<String>
        /// Windows of those apps that are recorded anyway.
        public var keptWindowIDs: Set<UInt32>
    }

    /// Decides which apps to leave out and which of their windows to record anyway.
    public static func plan(windows: [Window], neverRecord: Set<String>, hideDesktopIcons: Bool,
                            desktopIconLevel: Int = desktopIconLevel) -> Plan {
        var excluded = neverRecord
        excluded.insert(notificationCenterBundleID)
        if hideDesktopIcons { excluded.insert(finderBundleID) }

        let kept = windows.filter { window in
            // Apps the user chose never to record have no exceptions.
            guard let bundleID = window.bundleID, !neverRecord.contains(bundleID) else { return false }
            switch bundleID {
            case notificationCenterBundleID:
                // Desktop widgets sit below normal windows; banners and the
                // Notification Center panel sit above them.
                return window.layer < 0
            case finderBundleID:
                // Every Finder window except the desktop icons.
                return hideDesktopIcons && window.layer != desktopIconLevel
            default:
                return false
            }
        }
        return Plan(excludedBundleIDs: excluded, keptWindowIDs: Set(kept.map(\.id)))
    }

    /// Windows of the left-out apps. When this set changes, a window has opened or closed
    /// that the filter may need to know about, so it's worth rebuilding.
    public static func watchedWindowIDs(_ windows: [Window], plan: Plan) -> Set<UInt32> {
        Set(windows.filter { $0.bundleID.map(plan.excludedBundleIDs.contains) ?? false }.map(\.id))
    }
}
