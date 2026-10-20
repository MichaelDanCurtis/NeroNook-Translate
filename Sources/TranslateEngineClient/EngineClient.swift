import AVFoundation
import CryptoKit
import Foundation

/// Statistics the engine reports for one prepared voice.
public struct VoicePrepared: Sendable {
    public let slot: String
    public let seconds: Double
    public let prepareMs: Int
    public let language: String
    public let residentBytes: UInt64
    public let referenceSHA256: String
}

/// What the engine reports when a synthesis finishes, discarded or not.
public struct SynthesisDone: Sendable {
    public let frames: Int
    public let forwardedFrames: Int
    public let sampleRate: Int
    public let firstAudioMs: Int
    public let generationMs: Int
    public let discarded: Bool
    public let wastedMs: Int?
    public var audioSeconds: Double { Double(frames) / Double(sampleRate) }
    /// Generation time divided by audio produced: below 1 means faster than real time.
    public var realTimeFactor: Double { audioSeconds > 0 ? Double(generationMs) / 1000 / audioSeconds : .infinity }
}

public enum SynthesisEvent: Sendable {
    case audio(Data, sampleRate: Int)
    case done(SynthesisDone)
}

public struct EngineStats: Sendable {
    public let residentBytes: UInt64
    public let activeBytes: UInt64
    public let peakBytes: UInt64
    public let cacheBytes: UInt64
}

public struct TranslationResult: Sendable {
    public let text: String
    public let firstTokenMs: Int
    public let generationMs: Int
    public let chunks: Int        // streamed text chunks, not model tokens
}

/// The TranslateEngine client: voices, synthesis with out-of-band cancel, and the text translator.
/// Built on `HelperClient`, which owns the process and the ordered reply routing.
public actor EngineClient {
    nonisolated public let sampleRate: Int
    nonisolated public let loadMs: Int
    nonisolated public let startupMs: Int
    nonisolated public let readyResidentBytes: UInt64
    private let helper: HelperClient

    public static var sandboxProfile: String { HelperClient.sandboxProfile }
    nonisolated public var processIdentifier: Int32 { helper.processIdentifier }
    nonisolated public func usage() -> ProcessUsage? { helper.usage() }

    /// Spawns the engine and waits for `ready`. On any failure the helper is terminated, never leaked.
    public static func launch(engine: URL, model: URL, log: URL? = nil, timeout: TimeInterval = 120) async throws -> EngineClient {
        let helper = try await HelperClient.launch(helper: engine, arguments: ["--model", model.path], log: log, timeout: timeout)
        guard let sampleRate = helper.ready.int("sampleRate") else { await helper.terminate(); throw EngineClientProblem("The engine reported no sample rate.") }
        return EngineClient(helper: helper, sampleRate: sampleRate)
    }

    private init(helper: HelperClient, sampleRate: Int) {
        self.helper = helper
        self.sampleRate = sampleRate
        self.loadMs = helper.ready.int("loadMs") ?? -1
        self.startupMs = helper.startupMs
        self.readyResidentBytes = UInt64(helper.ready.int("residentBytes") ?? 0)
    }

    /// Decodes a reference recording to the engine's rate (off the actor, so a slow decode never delays
    /// a cancel) and asks the engine to prepare the slot's conditioning.
    public nonisolated func prepareVoice(slot: String, reference: URL, transcript: String, language: String) async throws -> VoicePrepared {
        let bytes = try Data(contentsOf: reference)
        guard bytes.count <= 64 * 1024 * 1024 else { throw EngineClientProblem("Reference file is too large.") }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let samples = try AudioDecoding.decode(reference, sampleRate: Double(sampleRate))
        let payload = samples.withUnsafeBytes { Data($0) }
        let reply = try await helper.request(["type": "prepareVoice", "slot": slot, "transcript": transcript, "language": language, "sampleRate": sampleRate], payload: payload)
        guard reply.type == "voiceReady" else { throw EngineClientProblem(reply.string("message") ?? "prepareVoice failed.") }
        return VoicePrepared(slot: slot, seconds: reply.double("seconds") ?? 0, prepareMs: reply.int("prepareMs") ?? -1,
                             language: reply.string("language") ?? language, residentBytes: UInt64(reply.int("residentBytes") ?? 0), referenceSHA256: digest)
    }

    /// Streams one synthesis. Audio payloads are Float32 little-endian mono at `sampleRate`, delivered in order.
    public func synthesize(id: String = UUID().uuidString, slot: String, text: String, streamingInterval: Double = 0.32) -> AsyncThrowingStream<SynthesisEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<SynthesisEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        let helper = self.helper
        let sampleRate = self.sampleRate
        Task {
            var expectedSeq = 0
            do {
                for try await message in await helper.subscribe(id, header: ["type": "synthesize", "slot": slot, "text": text, "streamingInterval": streamingInterval]) {
                    switch message.type {
                    case "audio":
                        let seq = message.int("seq") ?? -1
                        guard seq == expectedSeq else { throw EngineClientProblem("Audio arrived out of order (\(seq) after \(expectedSeq - 1)).") }
                        expectedSeq += 1
                        continuation.yield(.audio(message.payload, sampleRate: message.int("sampleRate") ?? sampleRate))
                    case "done":
                        await helper.finish(id)
                        continuation.yield(.done(SynthesisDone(frames: message.int("frames") ?? 0, forwardedFrames: message.int("forwardedFrames") ?? 0,
                                                              sampleRate: message.int("sampleRate") ?? sampleRate, firstAudioMs: message.int("firstAudioMs") ?? -1,
                                                              generationMs: message.int("generationMs") ?? -1, discarded: message.bool("discarded") ?? false,
                                                              wastedMs: message.int("wastedMs"))))
                        continuation.finish()
                        return
                    default:
                        continue
                    }
                }
                continuation.finish(throwing: EngineClientProblem("Synthesis ended without a done frame."))
            } catch {
                await helper.finish(id)
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    /// Out of band: the engine stops forwarding this request's audio and lets the generation finish.
    public func cancel(id: String) async throws { try await helper.send(["type": "cancel", "id": id]) }

    public func loadTranslator(model: URL) async throws -> Int {
        let reply = try await helper.request(["type": "loadTranslator", "model": model.path])
        return reply.int("loadMs") ?? -1
    }

    public func translate(_ text: String, from source: String?, to target: String, context: [String] = [], glossary: [String] = []) async throws -> TranslationResult {
        var header: [String: Any] = ["type": "translate", "text": text, "target": target, "context": context, "glossary": glossary]
        if let source { header["source"] = source }
        let reply = try await helper.request(header)
        return TranslationResult(text: reply.string("text") ?? "", firstTokenMs: reply.int("firstTokenMs") ?? -1, generationMs: reply.int("generationMs") ?? -1, chunks: reply.int("chunks") ?? 0)
    }

    public func stats() async throws -> EngineStats {
        let reply = try await helper.request(["type": "stats"])
        return EngineStats(residentBytes: UInt64(reply.int("residentBytes") ?? 0), activeBytes: UInt64(reply.int("activeBytes") ?? 0),
                           peakBytes: UInt64(reply.int("peakBytes") ?? 0), cacheBytes: UInt64(reply.int("cacheBytes") ?? 0))
    }

    public func ping() async throws { _ = try await helper.request(["type": "ping"]) }
    public func shutdown() async { await helper.shutdown() }
    public func terminate() async { await helper.terminate() }

    /// Kept for callers and tests that decode through the engine client.
    nonisolated static func decode(_ url: URL, sampleRate: Double) throws -> [Float] { try AudioDecoding.decode(url, sampleRate: sampleRate) }
}

/// Decodes any file AVAudioFile reads to mono Float32 at a given rate.
public enum AudioDecoding {
    public static func decode(_ url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw EngineClientProblem("Unsupported audio format.") }
        converter.downmix = true   // a stereo recording with the microphone on one input averages both channels, like ffmpeg -ac 1
        let sourceFrames = AVAudioFrameCount(file.length)
        guard sourceFrames > 0, let sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: sourceFrames) else { throw EngineClientProblem("Empty audio file.") }
        try file.read(into: sourceBuffer)
        let ratio = sampleRate / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(sourceFrames) * ratio) + 4096) else { throw EngineClientProblem("Could not allocate audio.") }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true; outStatus.pointee = .haveData; return sourceBuffer
        }
        guard status != .error, conversionError == nil, let channel = output.floatChannelData else { throw EngineClientProblem("Audio conversion failed.") }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    /// Writes mono Float32 samples as a 16-bit WAV file (for listening sets and codec copies).
    public static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { throw EngineClientProblem("Could not allocate audio.") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                                                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        try file.write(from: buffer)
    }
}
