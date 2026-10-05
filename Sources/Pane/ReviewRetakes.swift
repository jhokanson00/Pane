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

    /// Places the cut retakes in the silence around them (see `CutEdges`), once the
    /// narration's loudness is known; until then, where the words say.
    func updateCuts() {
        let found = retakes.filter(\.isCut).map(\.retake.cut)
        if let audioLevels, let spokenWords {
            cuts = CutEdges.placed(found, levels: audioLevels, words: spokenWords, pause: cutPause)
        } else {
            cuts = found
        }
    }

    /// The retakes kept, placed like cuts: Send to Final Cut puts each on a layer of its
    /// own, so it can be decided on there.
    var keptRetakes: [ClosedRange<Double>] {
        let kept = retakes.filter { !$0.isCut }.map(\.retake.cut)
        guard !kept.isEmpty else { return [] }
        if let audioLevels, let spokenWords {
            return CutEdges.placed(kept, levels: audioLevels, words: spokenWords, pause: cutPause)
        }
        return kept
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
        retakeState = .working("Looking for retakes…")
        let source = sourceURL, heard = spokenWords
        retakeTask = Task {
            do {
                let words: [CaptionWord]
                if let heard {
                    words = heard
                } else {
                    words = try await CaptionTranscriber.words(url: source) { stage in
                        Task { @MainActor [weak self] in
                            if case .downloading = stage { self?.retakeState = .working("Downloading speech recognition…") }
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                // How loud the narration is, to place the cuts in the silence. Without it the
                // cuts go where the words say.
                let levels = try? await AudioLevels.read(url: source)
                guard !Task.isCancelled else { return }
                spokenWords = words
                audioLevels = levels
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
}
