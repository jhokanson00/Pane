import AppKit
import SwiftUI

@main
struct PaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = RecorderModel.shared

    var body: some Scene {
        // The menu bar icon is how you stop a recording; the main window is set up by
        // AppDelegate so it opens on launch and reopens from the Dock.
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            if model.state == .recording {
                Text(model.isPaused ? "Paused \(model.elapsedString)" : "● \(model.elapsedString)")
            } else {
                Image(systemName: "record.circle")
            }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Support.checkForUpdates() }
            }
            CommandGroup(before: .windowList) {
                Button("Recording Management") { WindowPresenter.showRecordings() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
            }
            // Replaces macOS's "Help isn't available for Pane".
            CommandGroup(replacing: .help) {
                Button("Pane Help") { WindowPresenter.showHelp() }
                    .keyboardShortcut("?", modifiers: .command)
                Divider()
                Button("Report a Bug…") { Support.reportBug() }
                Button("Pane on GitHub") { Support.openRepo() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Support.updater
        WindowPresenter.showMain()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if RecorderModel.shared.state == .idle {
            WindowPresenter.showMain()
        }
        return true
    }

    /// A video dropped on the Dock icon or opened with "Open With → Pane".
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            RecorderModel.shared.review(videoAt: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
