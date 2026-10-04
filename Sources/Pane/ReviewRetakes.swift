import AVFoundation
import PaneKit

// Retakes in the review window: for a recording made with the teleprompter, the
// sentences said again are found from the narration, and each flubbed try is cut from
// exports (and skipped in the preview) unless it's kept.

/// A retake and whether its first try is cut.
struct RetakeCut: Identifiable, Equatable {
    let id = UUID()
    let retake: Retake
    var isCut = true
}

extension ReviewSession {
    enum RetakeState: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    /// The parts left out of exports: the cut retakes.
    var cuts: [ClosedRange<Double>] {
        retakes.filter(\.isCut).map(\.retake.cut)
    }

    /// How much the cuts take out, in seconds (overlaps counted once).
    var cutLength: Double {
        let edit = VideoEdit(cuts: cuts)
        return duration - edit.outputDuration(duration: duration)
    }

    /// Hears the narration (once; captions use the same words) and finds the retakes in it.
    func findRetakes() {
        guard let script, retakeTask == nil else { return }
        guard #available(macOS 26, *) else { return }
        if let spokenWords {
            retakes = RetakeFinder.find(script: script, words: spokenWords).map { RetakeCut(retake: $0) }
            return
        }
        retakeState = .working("Looking for retakes…")
        let source = sourceURL
        retakeTask = Task {
            do {
                let words = try await CaptionTranscriber.words(url: source) { stage in
                    Task { @MainActor [weak self] in
                        if case .downloading = stage { self?.retakeState = .working("Downloading speech recognition…") }
                    }
                }
                guard !Task.isCancelled else { return }
                spokenWords = words
                retakes = RetakeFinder.find(script: script, words: words).map { RetakeCut(retake: $0) }
                retakeState = .idle
            } catch {
                retakeState = error is CancellationError ? .idle : .failed(error.localizedDescription)
            }
            retakeTask = nil
        }
    }

    func setRetake(_ id: RetakeCut.ID, cut: Bool) {
        guard let index = retakes.firstIndex(where: { $0.id == id }) else { return }
        retakes[index].isCut = cut
    }

    func setAllRetakes(cut: Bool) {
        for index in retakes.indices { retakes[index].isCut = cut }
    }

    /// Playing through a cut jumps over it, so the preview plays as the export will.
    func skipCutWhilePlaying(at time: Double) {
        guard player.rate != 0,
              let cut = cuts.first(where: { $0.lowerBound <= time && time < $0.upperBound - 0.05 }) else { return }
        seek(to: cut.upperBound)
    }
}
