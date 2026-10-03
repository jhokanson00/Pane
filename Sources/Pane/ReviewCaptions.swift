import SwiftUI
import PaneKit

// Captions in the review window: made from the narration on this Mac, saved as a .srt
// file with each export, optionally drawn into the video, and sent to Final Cut as
// real captions.

extension ReviewSession {
    enum CaptionState: Equatable {
        case idle
        /// What's happening, and how far along it is (0–1).
        case working(String, Double)
        case failed(String)
    }

    /// Speech recognition for captions needs macOS 26.
    static var canMakeCaptions: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    func makeCaptions() {
        guard captionTask == nil else { return }
        guard #available(macOS 26, *) else { return }
        captionState = .working("Getting ready…", 0)
        let source = sourceURL
        captionTask = Task {
            let result: Result<Captions, Error>
            do {
                result = .success(try await CaptionTranscriber.transcribe(url: source) { stage in
                    Task { @MainActor [weak self] in
                        guard let self, case .working = self.captionState else { return }
                        switch stage {
                        case .downloading(let value): self.captionState = .working("Downloading speech recognition…", value)
                        case .transcribing(let value): self.captionState = .working("Making captions…", value)
                        }
                    }
                })
            } catch {
                result = .failure(error)
            }
            // A cancelled run leaves everything to whatever came after it.
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let made):
                captions = made
                captionState = .idle
            case .failure(let error):
                captionState = error is CancellationError ? .idle : .failed(error.localizedDescription)
            }
            captionTask = nil
        }
    }

    func cancelCaptions() {
        captionTask?.cancel()
        captionTask = nil
        captionState = .idle
    }

    /// Draws the captions into the video, when that's turned on.
    /// - Parameter cameraSeparate: The camera is its own layer, so the captions don't
    ///   need to stay clear of where it was.
    func captionEffect(cameraSeparate: Bool) -> (any FrameEffect)? {
        guard burnCaptions, let captions else { return nil }
        return CaptionRenderer(captions: captions, videoSize: videoSize,
                               cameraCircle: cameraSeparate ? nil : pointer?.cameraCircle)
    }

    /// Saves the captions as "<video name>.srt" next to an exported video.
    /// - Parameter trim: The part the video kept, so the captions match its times.
    func saveCaptions(besideVideo video: URL, trim: ClosedRange<Double>?) throws {
        guard let captions = captions?.trimmed(to: trim), !captions.cues.isEmpty else { return }
        try captions.srt.write(to: Self.captionsURL(for: video), atomically: true, encoding: .utf8)
    }

    static func captionsURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("srt")
    }
}

/// The Captions controls at the top of the export panel.
struct CaptionsSection: View {
    @ObservedObject var session: ReviewSession

    private var isExporting: Bool {
        if case .exporting = session.exportState { true } else { false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Captions").font(.headline)
            if !ReviewSession.canMakeCaptions {
                Text("Captions need macOS 26 or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                switch session.captionState {
                case .working(let label, let progress):
                    ProgressView(value: progress) {
                        Text("\(label) \(Int(progress * 100))%").font(.caption)
                    }
                    Button("Cancel") { session.cancelCaptions() }
                        .controlSize(.small)
                case .idle, .failed:
                    if case .failed(let message) = session.captionState {
                        Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                    }
                    if let captions = session.captions {
                        made(captions)
                    } else {
                        Button {
                            session.makeCaptions()
                        } label: {
                            Label("Make Captions", systemImage: "captions.bubble")
                        }
                        .help("Writes captions from your narration. Speech recognition runs on this Mac, so nothing "
                              + "is uploaded.")
                        Text("Turns what you say into captions, on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider().padding(.top, 4)
        }
        .disabled(isExporting)
    }

    @ViewBuilder
    private func made(_ captions: Captions) -> some View {
        if captions.cues.isEmpty {
            Text("No speech found, so there are no captions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Label(captions.cues.count == 1 ? "1 caption made" : "\(captions.cues.count) captions made",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                Spacer()
                Button("Make Again") { session.makeCaptions() }
                    .controlSize(.small)
            }
            Toggle("Burn captions into the video", isOn: $session.burnCaptions)
                .help("Draws the captions onto the exported video, so they show everywhere it's played")
            Text(ReviewSession.finalCut == nil
                 ? "Export Video also saves them as a .srt file next to the video."
                 : "Export Video also saves them as a .srt file next to the video. Send to Final Cut adds them as "
                   + "captions you can edit there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
