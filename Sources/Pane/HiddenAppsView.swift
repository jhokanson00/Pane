import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Windows from these apps are left out of every recording. You'll see whatever is
/// behind them instead.
struct HiddenAppsView: View {
    @EnvironmentObject private var model: RecorderModel
    @State private var apps: [AppEntry] = []

    struct AppEntry: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        var id: String { bundleID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Windows from checked apps never appear in recordings. Good for password managers, messages, and email.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding()

            List(apps) { app in
                Toggle(isOn: binding(for: app.bundleID)) {
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        Text(app.name)
                    }
                }
            }

            HStack {
                Button("Add App…", action: addApp)
                Spacer()
                Button("Refresh", action: reload)
            }
            .padding()
        }
        .onAppear(perform: reload)
    }

    private func binding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { model.hiddenBundleIDs.contains(bundleID) },
            set: { hidden in
                if hidden { model.hiddenBundleIDs.insert(bundleID) } else { model.hiddenBundleIDs.remove(bundleID) }
            }
        )
    }

    /// Hidden apps first, then everything currently running.
    private func reload() {
        var seen = Set<String>()
        var entries: [AppEntry] = []

        for bundleID in model.hiddenBundleIDs.sorted() {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            seen.insert(bundleID)
            entries.append(AppEntry(
                bundleID: bundleID,
                name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                icon: NSWorkspace.shared.icon(forFile: url.path)
            ))
        }

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppEntry? in
                guard let bundleID = app.bundleIdentifier, !seen.contains(bundleID),
                      bundleID != Bundle.main.bundleIdentifier else { return nil }
                seen.insert(bundleID)
                return AppEntry(bundleID: bundleID, name: app.localizedName ?? bundleID, icon: app.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        apps = entries + running
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                model.hiddenBundleIDs.insert(bundleID)
            }
        }
        reload()
    }
}
