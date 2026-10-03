import AppKit
import SwiftUI

/// The menu bar panel: quick start/stop. Setup lives in the main window.
struct MenuView: View {
    @EnvironmentObject private var model: RecorderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recordControls

            if let problem = model.problem {
                ProblemView(problem: problem)
            }

            Divider()
            HStack {
                Button("Open Pane") {
                    dismiss()
                    WindowPresenter.showMain()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 260)
    }

    @ViewBuilder
    private var recordControls: some View {
        switch model.state {
        case .idle:
            Button {
                dismiss()
                Task { await model.startRecording() }
            } label: {
                Label("Start Recording", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

        case .countingDown:
            HStack {
                Text("Starting…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelCountdown() }
            }

        case .recording:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if model.isPaused {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                        Text("Paused").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text("Recording").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.elapsedString).monospacedDigit()
                }
                HStack {
                    // Pausing keeps the panel open so it shows Paused; resuming closes it,
                    // as starting does.
                    Button {
                        if model.isPaused { dismiss() }
                        model.togglePause()
                    } label: {
                        Label(model.isPaused ? "Resume" : "Pause",
                              systemImage: model.isPaused ? "record.circle" : "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut("p", modifiers: .command)
                    .help(model.isPaused ? "Resume recording (⌘P)" : "Pause recording (⌘P)")

                    Button {
                        dismiss()
                        Task { await model.stopRecording() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)

        case .finishing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Saving…").foregroundStyle(.secondary)
            }
        }
    }
}
