import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The teleprompter's script window: write or paste the script, then rehearse with it or
/// record.
struct PrompterView: View {
    @EnvironmentObject private var model: RecorderModel
    @ObservedObject private var prompter = PrompterController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Write what you'll say. Put what to do in square brackets, like [Click Settings]: it shows in orange and ticks off when you click.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $prompter.scriptText)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) {
                    if prompter.scriptText.isEmpty {
                        Text(Self.example)
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                Button("Open…", action: open)
            }

            Divider()

            Toggle("Show the teleprompter while recording", isOn: $prompter.enabled)
                .disabled(!prompter.isAvailable)
            Picker("Text size", selection: $prompter.textSize) {
                ForEach(PrompterController.TextSize.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Text("While it's showing, press **Control-Option-↑** to start a sentence over, or **Control-Option-↓** to skip to the next one. Saying the sentence again works too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if prompter.isRehearsing {
                    Button("Stop Rehearsing") { prompter.end() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Rehearse") { prompter.rehearse(microphoneID: model.micID) }
                        .disabled(!prompter.hasScript || !prompter.isAvailable || model.state != .idle)
                }
                Text("Shows the teleprompter and follows your voice without recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !prompter.isAvailable {
                Label("Following your voice needs macOS 26 or later.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 460)
    }

    private var summary: String {
        let script = prompter.script
        guard prompter.hasScript else { return "No script yet" }
        let spoken = script.lines.filter { !$0.words.isEmpty }.count
        let minutes = Double(script.words.count) / 150
        var parts = ["\(spoken) \(spoken == 1 ? "line" : "lines")"]
        if !script.cues.isEmpty { parts.append("\(script.cues.count) \(script.cues.count == 1 ? "cue" : "cues")") }
        parts.append(minutes < 1 ? "under a minute" : String(format: "about %.0f min", minutes.rounded()))
        return parts.joined(separator: " · ")
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        prompter.scriptText = text
    }

    static let example = """
    Hi! Today I'll show you how to share a project. [Open the Projects page]
    First, pick the project you want to share.
    [Click Share]
    Then type your teammate's email and press Send.
    """
}
