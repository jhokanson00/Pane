import AppKit
import Sparkle

/// Updates (Sparkle, reading the appcast attached to the latest GitHub release) and the
/// Help menu's links to the GitHub repo.
@MainActor
enum Support {
    static let repo = URL(string: "https://github.com/jhokanson00/Pane")!

    /// Started at launch; checks once a day after the user agrees on the second launch.
    /// The feed must be signed with Pane's EdDSA key (SURequireSignedFeed in Info.plist).
    static let updater: SPUStandardUpdaterController = {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: feed, userDriverDelegate: nil
        )
        // Sparkle reads a feed URL from user defaults before Info.plist, so a stray
        // `defaults write … SUFeedURL` would move updates elsewhere. Drop it.
        controller.updater.clearFeedURLFromUserDefaults()
        controller.startUpdater()
        return controller
    }()

    /// Sparkle keeps its delegate weakly, so it lives here.
    private static let feed = FixedFeed()

    /// Always the feed in Info.plist, whatever user defaults say.
    private final class FixedFeed: NSObject, SPUUpdaterDelegate {
        func feedURLString(for updater: SPUUpdater) -> String? {
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        }
    }

    static func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    static func openRepo() {
        NSWorkspace.shared.open(repo)
    }

    /// Opens a new GitHub issue with the bug report form, its version fields filled in.
    /// Field ids match .github/ISSUE_TEMPLATE/bug_report.yml.
    static func reportBug() {
        var components = URLComponents(url: repo.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "app-version", value: appVersion),
            URLQueryItem(name: "macos-version", value: macOSVersion),
            URLQueryItem(name: "mac", value: macModel),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// "1.0.0 (3)".
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// "26.0 (25A354)".
    static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        if let build = sysctl("kern.osversion") { text += " (\(build))" }
        return text
    }

    /// "Mac15,3, Apple silicon".
    static var macModel: String {
        let chip: String
        #if arch(arm64)
        chip = "Apple silicon"
        #else
        chip = sysctl("sysctl.proc_translated") == nil ? "Intel" : "Intel build on Apple silicon"
        #endif
        return [sysctl("hw.model"), chip].compactMap { $0 }.joined(separator: ", ")
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
