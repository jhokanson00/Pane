import SwiftUI

/// A grid of open windows with live thumbnails. Pick one to record just that window.
struct WindowPickerSheet: View {
    @EnvironmentObject private var model: RecorderModel
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [WindowChoice] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a window to record").font(.headline)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding()

            Divider()

            Group {
                if isLoading && choices.isEmpty {
                    ProgressView("Finding windows…")
                } else if let errorMessage {
                    VStack(spacing: 10) {
                        Text(errorMessage).multilineTextAlignment(.center)
                        HStack {
                            Button("Open System Settings") { Permissions.openSettings(.screenRecording) }
                            Button("Quit & Reopen Pane") { Permissions.relaunch() }
                        }
                    }
                    .padding()
                } else if choices.isEmpty {
                    Text("No windows found on this desktop.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                            ForEach(choices) { choice in
                                Button {
                                    model.selectedWindow = choice
                                    dismiss()
                                } label: {
                                    WindowTile(choice: choice, isSelected: model.selectedWindow?.id == choice.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Text("Windows from apps on your Never Record list aren't shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 720, height: 520)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard await Permissions.ensureScreenRecording() else {
            errorMessage = "Pane needs Screen Recording access to see your windows."
            return
        }
        do {
            choices = try await WindowCatalog.load(hiddenBundleIDs: model.hiddenBundleIDs)
        } catch {
            errorMessage = "Couldn't list windows: \(error.localizedDescription)"
        }
    }
}

private struct WindowTile: View {
    let choice: WindowChoice
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25))
                if let thumbnail = choice.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                }
            }
            .frame(height: 130)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(isHovering ? 0.4 : 0.1),
                                  lineWidth: isSelected ? 3 : 1)
            )

            HStack(spacing: 6) {
                if let icon = choice.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(choice.displayTitle).lineLimit(1)
                    Text(choice.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
