import AppKit
import Combine
import SwiftUI

@MainActor
enum WindowPresenter {
    private static var mainWindow: NSWindow?
    private static var hiddenAppsWindow: NSWindow?
    private static var helpWindow: NSWindow?
    private static var prompterWindow: NSWindow?

    static func showMain() {
        let model = RecorderModel.shared
        if mainWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: MainView().environmentObject(model)
            ))
            window.title = "Pane"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("PaneMain")
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { model.setMainWindowVisible(false) }
            }
            mainWindow = window
        }
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
        model.setMainWindowVisible(true)
    }

    static func hideMain() {
        mainWindow?.orderOut(nil)
        hiddenAppsWindow?.orderOut(nil)
        RecorderModel.shared.setMainWindowVisible(false)
    }

    private static var reviewWindows: [ReviewSession.ID: NSWindow] = [:]
    private static var reviewSessions: [ReviewSession.ID: ReviewSession] = [:]
    private static var reviewTitles: [ReviewSession.ID: AnyCancellable] = [:]
    private static var recordingsWindow: NSWindow?

    /// The review windows open now.
    static var openReviews: [ReviewSession] { Array(reviewSessions.values) }

    /// Closes the review windows showing any of `files` (or something inside them).
    static func closeReviews(showing files: [URL]) {
        let paths = files.map(\.standardizedFileURL.path)
        for session in openReviews where paths.contains(where: { session.sourceURL.standardizedFileURL.path.hasPrefix($0) }) {
            reviewWindows[session.id]?.close()
            session.close()
        }
    }

    static func showReview(_ session: ReviewSession) {
        if reviewWindows[session.id] == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ReviewView(session: session)))
            // Follows the video's name when it's renamed.
            reviewTitles[session.id] = session.$sourceURL.sink { url in
                window.title = "Review – \(url.deletingPathExtension().lastPathComponent)"
            }
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1180, height: 720))
            window.isReleasedWhenClosed = false
            window.center()
            let id = session.id
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    session.player.pause()
                    reviewWindows[id] = nil
                    reviewSessions[id] = nil
                    reviewTitles[id] = nil
                }
            }
            reviewWindows[id] = window
            reviewSessions[id] = session
        }
        NSApp.activate()
        reviewWindows[session.id]?.makeKeyAndOrderFront(nil)
    }

    /// Every recording, with its size, to review, rename or move to the Trash.
    static func showRecordings() {
        if recordingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: RecordingsView().environmentObject(RecorderModel.shared)
            ))
            window.title = "Recordings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("PaneRecordings")
            recordingsWindow = window
        }
        NSApp.activate()
        recordingsWindow?.makeKeyAndOrderFront(nil)
        RecordingsLibrary.shared.refresh()
    }

    /// The how-to guide, from Help ▸ Pane Help or the main window.
    static func showHelp() {
        if helpWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HelpView()))
            window.title = "How to Use Pane"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 620, height: 720))
            window.isReleasedWhenClosed = false
            window.center()
            helpWindow = window
        }
        NSApp.activate()
        helpWindow?.makeKeyAndOrderFront(nil)
    }

    /// The teleprompter's script window.
    static func showPrompter() {
        if prompterWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: PrompterView().environmentObject(RecorderModel.shared)
            ))
            window.title = "Teleprompter"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 600, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("PanePrompter")
            prompterWindow = window
        }
        NSApp.activate()
        prompterWindow?.makeKeyAndOrderFront(nil)
    }

    static func showHiddenApps() {
        if hiddenAppsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: HiddenAppsView().environmentObject(RecorderModel.shared)
            ))
            window.title = "Never Record These Apps"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 420, height: 480))
            window.isReleasedWhenClosed = false
            window.center()
            hiddenAppsWindow = window
        }
        NSApp.activate()
        hiddenAppsWindow?.makeKeyAndOrderFront(nil)
    }
}
