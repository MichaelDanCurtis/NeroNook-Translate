import AVFoundation

/// Buffer helpers shared by capture, playback and the recognizer feeding code.
public enum PCMBuffers {
    /// Mono, non-interleaved Float32 at `sampleRate`; nil for a rate that is not positive and finite.
    public static func monoFloatFormat(sampleRate: Double) -> AVAudioFormat? {
        guard sampleRate > 0, sampleRate.isFinite else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// A mono Float32 buffer holding a copy of `samples` (an empty array gives an empty buffer).
    public static func buffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = monoFloatFormat(sampleRate: sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: source.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// Converts one buffer to `format` with a converter kept by the caller.
    ///
    /// Streaming: the converter keeps state between calls (a sample-rate converter holds back a few frames
    /// for its filter), and this tells it `.noDataNow` once `buffer` is consumed, so consecutive calls join up with
    /// no gap. The held-back frames come out on the next call; `flush(_:)` pushes them out at the end of a stream.
    /// Throws if `buffer` or `format` does not match the converter's formats, or the conversion fails.
    public static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, with converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        guard sameLayout(buffer.format, converter.inputFormat) else {
            throw AudioProblem("The audio buffer (\(describe(buffer.format))) does not match the converter input (\(describe(converter.inputFormat))).")
        }
        guard sameLayout(format, converter.outputFormat) else {
            throw AudioProblem("The target format (\(describe(format))) does not match the converter output (\(describe(converter.outputFormat))).")
        }
        return try run(converter, input: buffer, endOfStream: false)
    }

    /// Mono samples of a buffer: channel 0, `frameLength` samples (empty for a non-float buffer).
    public static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let frames = Int(buffer.frameLength)
        // Interleaved buffers keep all channels in the first pointer; step over the other channels.
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        if stride == 1 { return Array(UnsafeBufferPointer(start: channel, count: frames)) }
        return (0 ..< frames).map { channel[$0 * stride] }
    }

    // MARK: - Internal

    /// Pushes out the frames `converter` still holds at the end of a stream, then resets it for a new stream.
    static func flush(_ converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        defer { converter.reset() }
        return try run(converter, input: nil, endOfStream: true)
    }

    /// Same sample rate, channel count, sample type and interleaving: what the converter needs to accept a buffer.
    static func sameLayout(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat && a.isInterleaved == b.isInterleaved
    }

    /// Runs the converter on `input` (or on nothing) until it has produced everything it can, and returns that.
    /// The output buffer is sized with room to spare; if it still fills up, conversion continues into another
    /// buffer and the pieces are joined. `maxFramesPerPass` caps the output buffer size (tests use it to force that path).
    static func run(
        _ converter: AVAudioConverter,
        input: AVAudioPCMBuffer?,
        endOfStream: Bool,
        maxFramesPerPass: AVAudioFrameCount = .max
    ) throws -> AVAudioPCMBuffer {
        let format = converter.outputFormat
        let ratio = format.sampleRate / converter.inputFormat.sampleRate
        let capacity = max(1, min(maxFramesPerPass, AVAudioFrameCount((Double(input?.frameLength ?? 0) * ratio).rounded(.up)) + 1024))
        let feed = InputFeed(input)
        var pieces: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw AudioProblem("Could not allocate an audio buffer for conversion.")
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if let next = feed.take() {
                    inputStatus.pointee = .haveData
                    return next
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error {
                throw AudioProblem("Audio conversion failed: \(conversionError?.localizedDescription ?? "unknown error").")
            }
            if output.frameLength > 0 { pieces.append(output) }
            // `.haveData` means the output filled up and there may be more; anything else means done for now.
            if status != .haveData || output.frameLength == 0 { break }
        }
        return try join(pieces, format: format)
    }

    /// One buffer holding `pieces` back to back (any PCM layout: copies whole frames per audio buffer).
    private static func join(_ pieces: [AVAudioPCMBuffer], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if pieces.count == 1 { return pieces[0] }
        let total = pieces.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard let joined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(total, 1)) else {
            throw AudioProblem("Could not allocate an audio buffer for conversion.")
        }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let target = UnsafeMutableAudioBufferListPointer(joined.mutableAudioBufferList)
        var offset = 0
        for piece in pieces {
            let source = UnsafeMutableAudioBufferListPointer(piece.mutableAudioBufferList)
            let byteCount = Int(piece.frameLength) * bytesPerFrame
            for index in 0 ..< min(target.count, source.count) {
                guard let from = source[index].mData, let to = target[index].mData else { continue }
                (to + offset).copyMemory(from: from, byteCount: byteCount)
            }
            offset += byteCount
        }
        joined.frameLength = total
        return joined
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch\(format.isInterleaved ? ", interleaved" : "")"
    }
}

/// Hands the converter its one input buffer, once.
private final class InputFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
