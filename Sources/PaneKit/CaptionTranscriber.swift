import AVFoundation
import Speech

public enum CaptionError: LocalizedError {
    case unavailable
    case unsupportedLanguage(String)
    case noAudio

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Captions need speech recognition, which isn't available on this Mac."
        case .unsupportedLanguage(let name): "Captions aren't available in \(name) yet."
        case .noAudio: "This video has no sound to make captions from."
        }
    }
}

/// Turns a recording's narration into captions with Apple's speech recognition, entirely
/// on this Mac. Nothing is sent anywhere.
@available(macOS 26, *)
public enum CaptionTranscriber {
    public enum Stage: Sendable, Equatable {
        /// Getting the speech model for the language, the first time only.
        case downloading(Double)
        case transcribing(Double)
    }

    /// - Parameters:
    ///   - url: The recording. Its first sound track is used, which is the microphone in
    ///     Pane's recordings (system audio comes second).
    ///   - locale: The spoken language. Defaults to the Mac's.
    public static func transcribe(
        url: URL, locale: Locale = .current, rules: Captions.Rules = Captions.Rules(),
        progress: @escaping @Sendable (Stage) -> Void = { _ in }
    ) async throws -> Captions {
        let words = try await words(url: url, locale: locale, progress: progress)
        let language = locale.language.languageCode?.identifier ?? "en"
        return Captions(words: words, language: language, rules: rules)
    }

    /// Every spoken word, timed on the video's timeline.
    public static func words(
        url: URL, locale: Locale = .current, progress: @escaping @Sendable (Stage) -> Void = { _ in }
    ) async throws -> [CaptionWord] {
        guard SpeechTranscriber.isAvailable else { throw CaptionError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw CaptionError.unsupportedLanguage(Locale.current.localizedString(forIdentifier: locale.identifier)
                                                   ?? locale.identifier)
        }
        let transcriber = makeTranscriber(locale: supported)
        try await installModel(for: transcriber, progress: progress)

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pane Captions \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try await extractSpeech(from: url, to: folder.appendingPathComponent("speech.caf"), format: format)
        let file = try AVAudioFile(forReading: audio.url)
        progress(.transcribing(0))

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let offset = audio.start
        let duration = max(audio.duration, 0.001)
        let reading = Task {
            var pieces: [(text: String, start: Double?, end: Double?)] = []
            for try await result in transcriber.results {
                let text = result.text
                for (range, runRange) in text.runs[\.audioTimeRange] {
                    let piece = String(text[runRange].characters)
                    if let range, range.isValid, !range.duration.seconds.isNaN {
                        pieces.append((piece, offset + range.start.seconds, offset + range.end.seconds))
                    } else {
                        pieces.append((piece, nil, nil))
                    }
                }
                // Results end with a space between them, so words from two results never run together.
                pieces.append((" ", nil, nil))
                progress(.transcribing(min(1, result.range.end.seconds / duration)))
            }
            return pieces
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            reading.cancel()
            throw error
        }
        let pieces = try await withTaskCancellationHandler {
            try await reading.value
        } onCancel: {
            reading.cancel()
        }
        try Task.checkCancellation()
        progress(.transcribing(1))
        return CaptionWord.words(fromPieces: pieces)
    }

    /// Downloads the speech model for the language if this Mac doesn't have it yet. macOS
    /// keeps it for every app, so this happens once.
    private static func installModel(for transcriber: SpeechTranscriber,
                                     progress: @escaping @Sendable (Stage) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        progress(.downloading(0))
        let observation = request.progress.observe(\.fractionCompleted) { value, _ in
            progress(.downloading(value.fractionCompleted))
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    /// Finished text only (no running guesses), with the time of every piece.
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange])
    }

    /// Whether the speech model for `locale` still has to be downloaded.
    public static func needsDownload(locale: Locale = .current) async -> Bool {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
        let request = try? await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(locale: supported)])
        return request != nil
    }

    /// Copies the first sound track to an audio file in the format the recognizer works in.
    /// - Returns: The file, when its audio starts in the video, and how long it is.
    private static func extractSpeech(from url: URL, to destination: URL, format: AVAudioFormat?)
        async throws -> (url: URL, start: Double, duration: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CaptionError.noAudio }
        let duration = try await track.load(.timeRange).duration.seconds

        // Mono at the recognizer's rate; the recognizer would otherwise convert it itself.
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        if let format, format.commonFormat == .pcmFormatInt16 {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        } else {
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
        }
        settings[AVSampleRateKey] = format?.sampleRate ?? 16_000

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw ExportError.failed(reader.error) }

        var file: AVAudioFile?
        var start: Double?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let description = sample.formatDescription else { continue }
            let sampleFormat = AVAudioFormat(cmAudioFormatDescription: description)
            if file == nil {
                file = try AVAudioFile(forWriting: destination, settings: sampleFormat.settings,
                                       commonFormat: sampleFormat.commonFormat, interleaved: sampleFormat.isInterleaved)
                start = sample.presentationTimeStamp.seconds
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sampleFormat, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            guard status == noErr else { continue }
            try file?.write(from: buffer)
        }
        if reader.status == .failed { throw ExportError.failed(reader.error) }
        guard file != nil else { throw CaptionError.noAudio }
        file = nil  // Closes it, so it can be read.
        let begin = start ?? 0
        return (destination, begin.isFinite ? begin : 0, duration)
    }
}
