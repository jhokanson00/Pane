import CoreMedia

/// The pauses in a recording, and where everything captured around them lands in the
/// finished file.
///
/// Capture keeps running while paused (so the screen is current and the camera bubble
/// stays live), but nothing captured during a pause is written. Everything after a pause
/// is moved back by the time spent paused, so the file has no gap and its timestamps
/// keep increasing, which AVAssetWriter requires.
///
/// Times are seconds on one clock (the host clock the recorder uses). Each decision is
/// made from a sample's own capture time, not from when it arrives, so audio that comes
/// in a little late is still placed correctly.
public struct RecordingPauses: Equatable, Sendable {
    public struct Pause: Equatable, Sendable {
        public var start: Double
        /// nil while still paused.
        public var end: Double?
    }

    public private(set) var pauses: [Pause] = []

    public init() {}

    public var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    /// Total time spent paused so far, as of `time`.
    public func pausedDuration(before time: Double) -> Double {
        pauses.reduce(0) { total, pause in
            total + max(0, min(time, pause.end ?? .infinity) - pause.start)
        }
    }

    /// Starts a pause. Returns false if already paused.
    @discardableResult
    public mutating func pause(at time: Double) -> Bool {
        guard !isPaused else { return false }
        // The clock only moves forward, so a pause never starts inside the last one.
        pauses.append(Pause(start: max(time, pauses.last?.end ?? time), end: nil))
        return true
    }

    /// Ends the current pause. Returns false if not paused.
    @discardableResult
    public mutating func resume(at time: Double) -> Bool {
        guard isPaused else { return false }
        let last = pauses.count - 1
        pauses[last].end = max(time, pauses[last].start)
        return true
    }

    /// Whether something captured at `time` falls in a pause and should be left out.
    /// A pause covers its start up to, but not including, its end.
    public func isPaused(at time: Double) -> Bool {
        pauses.contains { time >= $0.start && time < ($0.end ?? .infinity) }
    }

    /// Where `time` lands in the finished file, with the pauses before it cut out. A time
    /// inside a pause lands where that pause started, so stopping while paused ends the
    /// file right where the pause began.
    public func recordedTime(at time: Double) -> Double {
        time - pausedDuration(before: time)
    }

    /// The same as `recordedTime(at:)`, for writer timestamps. Unchanged until the first
    /// pause, so a recording that's never paused is written exactly as before.
    public func recordedTime(at time: CMTime) -> CMTime {
        let paused = pausedDuration(before: time.seconds)
        guard paused > 0 else { return time }
        return CMTimeSubtract(time, CMTime(seconds: paused, preferredTimescale: 1_000_000_000))
    }

    /// Time actually recorded between `start` and `time`, for the elapsed-time display.
    public func recordedDuration(from start: Double, to time: Double) -> Double {
        max(0, recordedTime(at: time) - recordedTime(at: start))
    }

    /// The moment a screen picture is known to show, when it's written at `time`.
    ///
    /// The screen capture only delivers a new picture when something changes, so the
    /// latest picture still matches the screen until the next one arrives. One captured
    /// before or during a pause and still the latest after resuming therefore shows the
    /// screen as it was on resuming. The pointer is placed by this moment, and the pause
    /// in between isn't in the video.
    public func pictureTime(captured: Double, at time: Double) -> Double {
        guard let resumed = pauses.last(where: { ($0.end ?? .infinity) <= time })?.end else { return captured }
        return max(captured, resumed)
    }

    /// A run of samples to keep from an audio buffer, and where it starts in the file.
    public struct Piece: Equatable, Sendable {
        /// Index of the first sample to keep.
        public var first: Int
        public var count: Int
        /// Where the first kept sample lands in the finished file.
        public var time: Double
    }

    /// Splits a buffer of `count` evenly spaced samples, the first captured at `start`,
    /// into the runs captured outside pauses. A buffer can straddle a pause's start, its
    /// end, or a whole short pause, so there can be up to one more run than pauses.
    public func pieces(start: Double, count: Int, rate: Double) -> [Piece] {
        guard count > 0, rate > 0 else { return [] }
        /// The first sample captured at or after `time`.
        func firstSample(atOrAfter time: Double) -> Int {
            // A small allowance so float error doesn't push a sample that lands exactly
            // on a boundary to the wrong side.
            min(count, max(0, Int(((time - start) * rate - 1e-6).rounded(.up))))
        }
        var pieces: [Piece] = []
        var keepFrom = 0
        for pause in pauses {
            let pausedFrom = firstSample(atOrAfter: pause.start)
            let pausedTo = pause.end.map(firstSample(atOrAfter:)) ?? count
            guard pausedTo > pausedFrom else { continue }
            if pausedFrom > keepFrom {
                pieces.append(piece(keepFrom, pausedFrom - keepFrom, start: start, rate: rate))
            }
            keepFrom = max(keepFrom, pausedTo)
        }
        if keepFrom < count {
            pieces.append(piece(keepFrom, count - keepFrom, start: start, rate: rate))
        }
        return pieces
    }

    private func piece(_ first: Int, _ count: Int, start: Double, rate: Double) -> Piece {
        Piece(first: first, count: count, time: recordedTime(at: start + Double(first) / rate))
    }
}

/// Cuts the paused stretches out of one audio stream and moves the rest back to close
/// the gap. Keep one per stream (microphone, system audio), since each remembers where
/// its last buffer ended.
public struct PausedAudio {
    /// Where the last buffer handed out ends in the finished file.
    private var end: CMTime?

    public init() {}

    /// The parts of `buffer` to write, retimed. Before the first pause the buffer comes
    /// back unchanged; inside a pause, nothing comes back.
    public mutating func retime(_ buffer: CMSampleBuffer, pauses: RecordingPauses) -> [CMSampleBuffer] {
        let start = buffer.presentationTimeStamp
        guard start.isValid else { return [] }
        let count = CMSampleBufferGetNumSamples(buffer)
        guard let format = buffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM, description.mSampleRate > 0, count > 0
        else {
            // Not plain audio samples, so it can't be cut: keep it or drop it whole.
            guard !pauses.isPaused(at: start.seconds) else { return [] }
            if pauses.pauses.isEmpty { return [buffer] }
            let perSample = CMTimeMultiplyByRatio(buffer.duration, multiplier: 1, divisor: Int32(max(1, count)))
            return Self.retimed(buffer, to: pauses.recordedTime(at: start), sampleDuration: perSample).map { [$0] } ?? []
        }

        // Lengths come from the sample count, since a buffer's own duration may be
        // labeled per buffer rather than per sample.
        let rate = description.mSampleRate
        let scale = CMTimeScale(rate.rounded())
        let sample = CMTime(value: 1, timescale: scale)
        if pauses.pauses.isEmpty {
            end = CMTimeAdd(start, CMTime(value: CMTimeValue(count), timescale: scale))
            return [buffer]
        }
        return pauses.pieces(start: start.seconds, count: count, rate: rate).compactMap { piece in
            let captured = CMTimeAdd(start, CMTime(value: CMTimeValue(piece.first), timescale: scale))
            var time = pauses.recordedTime(at: captured)
            // Where a pause was cut, the two sides can miss each other by less than a
            // sample from rounding; join them so the audio stays continuous.
            if let end, abs(CMTimeSubtract(time, end).seconds) < 1.5 / rate { time = end }
            let whole = piece.first == 0 && piece.count == count
            guard let out = whole ? Self.retimed(buffer, to: time, sampleDuration: sample)
                                  : Self.copy(buffer, first: piece.first, count: piece.count, at: time, rate: scale)
            else { return nil }
            end = CMTimeAdd(time, CMTime(value: CMTimeValue(piece.count), timescale: scale))
            return out
        }
    }

    private static func retimed(_ buffer: CMSampleBuffer, to time: CMTime, sampleDuration: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: sampleDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    /// Copies samples `first..<first + count` into a new buffer starting at `time`. Works
    /// for interleaved audio (the microphone) and one-buffer-per-channel audio (system
    /// audio from ScreenCaptureKit).
    static func copy(_ buffer: CMSampleBuffer, first: Int, count: Int, at time: CMTime,
                     rate: CMTimeScale) -> CMSampleBuffer? {
        let total = CMSampleBufferGetNumSamples(buffer)
        guard let format = buffer.formatDescription, first >= 0, count > 0, first + count <= total else { return nil }

        var size = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr
        else { return nil }
        let sourceMemory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        let pieceMemory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer {
            sourceMemory.deallocate()
            pieceMemory.deallocate()
        }
        let sourceList = sourceMemory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: sourceList, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
        else { return nil }

        // Point each channel buffer at the kept samples; the new buffer copies them.
        pieceMemory.copyMemory(from: sourceMemory, byteCount: size)
        let pieceList = pieceMemory.bindMemory(to: AudioBufferList.self, capacity: 1)
        for (index, source) in UnsafeMutableAudioBufferListPointer(sourceList).enumerated() {
            guard let data = source.mData else { return nil }
            let bytesPerSample = Int(source.mDataByteSize) / total
            UnsafeMutableAudioBufferListPointer(pieceList)[index] = AudioBuffer(
                mNumberChannels: source.mNumberChannels,
                mDataByteSize: UInt32(bytesPerSample * count),
                mData: data + bytesPerSample * first)
        }

        var out: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: count, presentationTimeStamp: time,
            packetDescriptions: nil, sampleBufferOut: &out) == noErr, let out
        else { return nil }
        // The source's memory has to stay alive until its samples are copied.
        let copied = withExtendedLifetime(block) {
            CMSampleBufferSetDataBufferFromAudioBufferList(
                out, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pieceList)
        }
        return copied == noErr ? out : nil
    }
}
