import XCTest
@testable import PaneKit

final class CaptureExclusionTests: XCTestCase {
    /// Levels as measured on macOS 27.
    let iconLevel = -2_147_483_603
    lazy var windows: [CaptureExclusion.Window] = [
        .init(id: 1, bundleID: "com.apple.finder", layer: iconLevel),          // desktop icons, display 1
        .init(id: 2, bundleID: "com.apple.finder", layer: iconLevel),          // desktop icons, display 2
        .init(id: 3, bundleID: "com.apple.finder", layer: 0),                  // a Finder window
        .init(id: 4, bundleID: "com.apple.finder", layer: 103),                // a Finder pop-up
        .init(id: 5, bundleID: "com.apple.notificationcenterui", layer: 21),   // banners
        .init(id: 6, bundleID: "com.apple.notificationcenterui", layer: -2_147_483_601), // a widget
        .init(id: 7, bundleID: "com.apple.wallpaper.agent", layer: -2_147_483_625),      // wallpaper
        .init(id: 8, bundleID: "com.apple.Safari", layer: 0),
        .init(id: 9, bundleID: "com.apple.MobileSMS", layer: 0),
        .init(id: 10, bundleID: nil, layer: -2_147_483_602),
    ]

    func plan(hideIcons: Bool, neverRecord: Set<String> = ["com.apple.MobileSMS"]) -> CaptureExclusion.Plan {
        CaptureExclusion.plan(windows: windows, neverRecord: neverRecord, hideDesktopIcons: hideIcons,
                              desktopIconLevel: iconLevel)
    }

    func testNotificationsAreAlwaysLeftOutButWidgetsStay() {
        let plan = plan(hideIcons: false)
        XCTAssertEqual(plan.excludedBundleIDs, ["com.apple.MobileSMS", "com.apple.notificationcenterui"])
        XCTAssertEqual(plan.keptWindowIDs, [6])
    }

    func testHidingIconsLeavesOutOnlyFindersDesktopIconWindows() {
        let plan = plan(hideIcons: true)
        XCTAssertEqual(plan.excludedBundleIDs,
                       ["com.apple.MobileSMS", "com.apple.notificationcenterui", "com.apple.finder"])
        // Finder's own windows and pop-ups come back; the icon windows don't. The
        // wallpaper belongs to another app and is never left out.
        XCTAssertEqual(plan.keptWindowIDs, [3, 4, 6])
        XCTAssertFalse(plan.excludedBundleIDs.contains("com.apple.wallpaper.agent"))
    }

    func testNeverRecordAppsHaveNoExceptions() {
        let plan = plan(hideIcons: true, neverRecord: ["com.apple.finder", "com.apple.notificationcenterui"])
        XCTAssertTrue(plan.keptWindowIDs.isEmpty)
        XCTAssertEqual(plan.excludedBundleIDs, ["com.apple.finder", "com.apple.notificationcenterui"])
    }

    /// The icons sit just above the desktop picture and below every app window.
    func testDesktopIconLevelIsBetweenTheDesktopAndNormalWindows() {
        XCTAssertGreaterThan(CaptureExclusion.desktopIconLevel, Int(CGWindowLevelForKey(.desktopWindow)))
        XCTAssertLessThan(CaptureExclusion.desktopIconLevel, Int(CGWindowLevelForKey(.normalWindow)))
    }

    func testWatchesWindowsOfLeftOutApps() {
        XCTAssertEqual(CaptureExclusion.watchedWindowIDs(windows, plan: plan(hideIcons: false)), [5, 6, 9])
        XCTAssertEqual(CaptureExclusion.watchedWindowIDs(windows, plan: plan(hideIcons: true)), [1, 2, 3, 4, 5, 6, 9])
    }
}
