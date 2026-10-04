import AVFoundation
import Speech

/// Live speech recognition for the teleprompter: microphone audio in, words out as they're
/// heard, on this Mac. Reports the recognizer's running guess as well as finished words, so
/// the prompter can move before a sentence ends.
@available(macOS 26, *)
public final class LiveTranscriber: @unchecked Sendable {
    public struct Heard: Sendable {
        /// Words the recognizer won't change any more.
        public var finished: [String]
        /// Its current guess at the words after them, which may still change.
        public var guess: [String]
        /// How far into the audio the recognizer has got, in seconds since the first buffer.
        public var audioTime: Double

        public var all: [String] { finished + guess }
    }

    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let reading: Task<Void, Error>
    // Only touched from `append`, which the caller keeps on one queue.
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    /// Starts listening. `onHeard` is called on a background task after every update.
    /// - Parameter vocabulary: Words to expect, such as the script's names and terms.
    public static func start(locale: Locale = .current, vocabulary: [String] = [],
                             onHeard: @escaping @Sendable (Heard) -> Void) async throws -> LiveTranscriber {
        guard SpeechTranscriber.isAvailable else { throw CaptionError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw CaptionError.unsupportedLanguage(Locale.current.localizedString(forIdentifier: locale.identifier)
                                                   ?? locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        try await CaptionTranscriber.installModel(for: transcriber) { _ in }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CaptionError.unavailable
        }
        let context = AnalysisContext()
        if !vocabulary.isEmpty { context.contextualStrings[.general] = vocabulary }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)

        let reading = Task {
            var finished: [String] = []
            for try await result in transcriber.results {
                let words = String(result.text.characters).split(whereSeparator: \.isWhitespace).map(String.init)
                let end = result.range.end.seconds
                if result.isFinal {
                    finished += words
                    onHeard(Heard(finished: finished, guess: [], audioTime: end.isFinite ? end : 0))
                } else {
                    onHeard(Heard(finished: finished, guess: words, audioTime: end.isFinite ? end : 0))
                }
            }
        }
        try await analyzer.start(inputSequence: stream)
        return LiveTranscriber(analyzer: analyzer, format: format, input: continuation, reading: reading)
    }

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat,
                 input: AsyncStream<AnalyzerInput>.Continuation, reading: Task<Void, Error>) {
        self.analyzer = analyzer
        self.format = format
        self.input = input
        self.reading = reading
    }

    /// Feeds audio in any format; it's converted to what the recognizer wants. Call from one
    /// queue at a time.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// Feeds a captured audio buffer (PCM, as Pane's microphone capture delivers it).
    public func append(_ sampleBuffer: CMSampleBuffer) {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let description = sampleBuffer.formatDescription else { return }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        append(buffer)
    }

    /// Stops listening once the audio fed so far has been heard.
    public func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try? await reading.value
    }

    /// Stops at once, dropping audio not yet heard.
    public func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        reading.cancel()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converterSource != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterSource = buffer.format
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
