import AVFoundation

/// The export's side of click sounds. Most web players only play a video's first audio
/// track, so the clicks go into that one (the microphone): it's decoded, the clicks are
/// added at their exact samples, and it's encoded again as AAC at 48 kHz with the same
/// number of channels. A recording with no audio gets one track with just the clicks.
enum ClickSoundAudio {
    /// What audio is decoded to (the first track for click sounds, every track in a
    /// trimmed copy): interleaved 32-bit float at 48 kHz.
    static let decodedSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: ClickSound.sampleRate,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// AAC at 48 kHz with `format`'s channels (mono when there's no format), at a rate
    /// that keeps narration clean.
    static func encodedSettings(like format: CMFormatDescription?) -> [String: Any] {
        let description = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = max(1, Int(description?.mChannelsPerFrame ?? 1))
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: ClickSound.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: min(128_000 * channels, 320_000),
        ]
        // More than two channels need their layout spelled out.
        if channels > 2, let format {
            var size = 0
            if let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size), size > 0 {
                settings[AVChannelLayoutKey] = Data(bytes: layout, count: size)
            }
        }
        return settings
    }

    /// The same audio with the clicks added, or nil when no click falls in it (or it isn't
    /// the decoded format), in which case the original is used as is.
    static func mixed(_ sample: CMSampleBuffer, with mixer: ClickSoundMixer) -> CMSampleBuffer? {
        edited(sample, when: { mixer.overlaps(start: $0, frames: $1) }) { samples, channels, start in
            mixer.mix(into: samples, channels: channels, start: start)
        }
    }

    /// The same audio faded where kept parts meet, or nil when no join falls in it.
    static func faded(_ sample: CMSampleBuffer, with fades: JoinFades) -> CMSampleBuffer? {
        edited(sample, when: { fades.overlaps(start: $0, frames: $1) }) { samples, channels, start in
            fades.apply(to: samples, channels: channels, start: start)
        }
    }

    /// A copy of decoded audio (see `decodedSettings`) changed by `edit`, which gets the
    /// interleaved samples, the channel count and the first sample's position at 48 kHz.
    /// Nil when `overlaps` (given that position and the length) says there's nothing to
    /// change, or the audio isn't in the decoded format.
    private static func edited(
        _ sample: CMSampleBuffer, when overlaps: (Int, Int) -> Bool,
        edit: (UnsafeMutableBufferPointer<Float>, Int, Int) -> Void
    ) -> CMSampleBuffer? {
        guard let format = sample.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM, description.mBitsPerChannel == 32,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              Int(description.mSampleRate) == ClickSound.sampleRate,
              let source = sample.dataBuffer
        else { return nil }
        let channels = Int(description.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(sample)
        let start = samplePosition(sample.presentationTimeStamp)
        guard channels > 0, frames > 0, overlaps(start, frames) else { return nil }

        let length = CMBlockBufferGetDataLength(source)
        guard length >= frames * channels * MemoryLayout<Float>.size,
              let block = makeBlock(length: length) else { return nil }
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                                          dataPointerOut: &pointer) == noErr, let pointer,
              CMBlockBufferCopyDataBytes(source, atOffset: 0, dataLength: length, destination: pointer) == noErr
        else { return nil }
        pointer.withMemoryRebound(to: Float.self, capacity: frames * channels) { floats in
            edit(UnsafeMutableBufferPointer(start: floats, count: frames * channels), channels, start)
        }
        return makeSample(block: block, format: format, frames: frames, time: sample.presentationTimeStamp)
    }

    /// `time` in samples at 48 kHz.
    static func samplePosition(_ time: CMTime) -> Int {
        Int(CMTimeConvertScale(time, timescale: CMTimeScale(ClickSound.sampleRate), method: .roundHalfAwayFromZero).value)
    }

    fileprivate static func makeBlock(length: Int) -> CMBlockBuffer? {
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        return status == noErr ? block : nil
    }

    fileprivate static func makeSample(block: CMBlockBuffer, format: CMFormatDescription, frames: Int,
                                       time: CMTime) -> CMSampleBuffer? {
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }
}

/// For a recording with no audio: silence the length of the video (or the trimmed part of
/// it), with the clicks in it, handed out a tenth of a second at a time, timed on the
/// recording's own timeline like its other audio would be.
final class ClickOnlyAudio: @unchecked Sendable {
    private let mixer: ClickSoundMixer
    private let first: Int
    private let total: Int
    private var position: Int
    private let format: CMFormatDescription?

    /// - Parameters: start, end: The part of the source to cover, in seconds.
    init(mixer: ClickSoundMixer, from start: Double = 0, to end: Double) {
        self.mixer = mixer
        first = Int((start * Double(ClickSound.sampleRate)).rounded())
        total = Int((end * Double(ClickSound.sampleRate)).rounded())
        position = first
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(ClickSound.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        self.format = format
    }

    /// The next stretch, or nil once the whole length has been handed out.
    func next() -> CMSampleBuffer? {
        guard position < total, let format else { return nil }
        let frames = min(ClickSound.sampleRate / 10, total - position)
        let length = frames * MemoryLayout<Float>.size
        guard let block = ClickSoundAudio.makeBlock(length: length) else { return nil }
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        pointer.withMemoryRebound(to: Float.self, capacity: frames) { floats in
            let buffer = UnsafeMutableBufferPointer(start: floats, count: frames)
            buffer.initialize(repeating: 0)
            mixer.mix(into: buffer, channels: 1, start: position)
        }
        let time = CMTime(value: CMTimeValue(position), timescale: CMTimeScale(ClickSound.sampleRate))
        position += frames
        return ClickSoundAudio.makeSample(block: block, format: format, frames: frames, time: time)
    }
}
