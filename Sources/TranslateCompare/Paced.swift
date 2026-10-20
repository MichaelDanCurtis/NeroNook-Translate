import AVFoundation
import Foundation
import Speech
import TranslateEngineClient

// Paced runs (plan §6.1): each phrase is fed at wall-clock pace, so final-result and partial-caption delays
// are measured the way a live call sees them. Phrase boundaries come from an energy gate on the recording,
// never from the gold text, so every recognizer gets the same phrases. The clock starts once the
// recognizer's session is open and the first chunk is due; delays are measured from the phrase's nominal
// end (clock start plus the phrase's duration), so a recognizer that falls behind real time pays for its backlog.

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
func milliseconds(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
func sleep(until due: Double) async throws {
    let now = uptime()
    if due > now { try await Task.sleep(nanoseconds: UInt64((due - now) * 1_000_000_000)) }
}
func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

// MARK: - Phrase splitting

public enum PhraseSplitter {
    public struct Phrase: Codable, Sendable, Equatable {
        public let start: Int   // sample index
        public let end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
    }

    /// Energy gate on 20 ms frames: speech is 12 dB above the clip's 20th-percentile level and above a
    /// ceiling of -45 dBFS that drops to 20 dB under the clip's 90th-percentile level for quiet recordings,
    /// with 100 ms of hangover. Runs closer than `gapSeconds` merge; phrases shorter than `minSeconds` join
    /// the next one; phrases longer than `maxSeconds` are cut at their quietest interior frame. Each phrase
    /// keeps 140 ms of margin, the last one included, so trailing silence is not fed. A clip with no level
    /// contrast (silence, or speech without any pause) is cut by length alone. The floor estimate assumes at
    /// least a fifth of the frames are quiet. Audio outside every phrase is never fed; `coverage` says how much was.
    public static func split(_ samples: [Float], sampleRate: Int = 16_000, gapSeconds: Double = 0.6, minSeconds: Double = 1.0, maxSeconds: Double = 15.0) -> [Phrase] {
        guard !samples.isEmpty else { return [] }
        let frame = max(1, sampleRate / 50)
        let frames = samples.count / frame
        guard frames >= 10 else { return [Phrase(start: 0, end: samples.count)] }
        var level = [Double](repeating: -120, count: frames)
        samples.withUnsafeBufferPointer { buffer in
            for i in 0..<frames {
                var sum = 0.0
                for j in (i * frame)..<((i + 1) * frame) { let s = Double(buffer[j]); sum += s * s }
                level[i] = 10 * log10(sum / Double(frame) + 1e-12)
            }
        }
        let sorted = level.sorted()
        let floor = sorted[Int(Double(frames - 1) * 0.2)]
        let loud = sorted[Int(Double(frames - 1) * 0.9)]
        let threshold = max(floor + 12, min(-45, loud - 20))
        var speech = [Bool](repeating: false, count: frames)
        for i in 0..<frames where level[i] > threshold {
            for j in max(0, i - 5)...min(frames - 1, i + 5) { speech[j] = true }
        }
        var runs: [(start: Int, end: Int)] = []
        var i = 0
        while i < frames {
            guard speech[i] else { i += 1; continue }
            var j = i
            while j < frames, speech[j] { j += 1 }
            runs.append((start: i, end: j))
            i = j
        }
        // No frame stands out (silence, or speech with no pause at all): treat the clip as one run, which
        // the length limit below still cuts into phrases at its quietest frames.
        if runs.isEmpty { runs = [(start: 0, end: frames)] }
        let gap = Int(gapSeconds * 50)
        var merged = [runs[0]]
        for run in runs.dropFirst() {
            if run.start - merged[merged.count - 1].end < gap { merged[merged.count - 1].end = run.end } else { merged.append(run) }
        }
        let minFrames = Int(minSeconds * 50)
        var phrases: [(start: Int, end: Int)] = []
        var pending: (start: Int, end: Int)?
        for run in merged {
            let current: (start: Int, end: Int) = pending.map { (start: $0.start, end: run.end) } ?? run
            pending = nil
            if current.end - current.start < minFrames { pending = current } else { phrases.append(current) }
        }
        if let pending {
            if phrases.isEmpty { phrases.append(pending) } else { phrases[phrases.count - 1].end = pending.end }
        }
        let maxFrames = Int(maxSeconds * 50)
        var result: [(start: Int, end: Int)] = []
        var queue = phrases
        while !queue.isEmpty {
            let phrase = queue.removeFirst()
            if phrase.end - phrase.start <= maxFrames { result.append(phrase); continue }
            let low = phrase.start + (phrase.end - phrase.start) * 3 / 10
            let high = phrase.start + (phrase.end - phrase.start) * 7 / 10
            var cut = low
            for f in low..<high where level[f] < level[cut] { cut = f }
            queue.insert((start: cut, end: phrase.end), at: 0)
            queue.insert((start: phrase.start, end: cut), at: 0)
        }
        let pad = 7
        return result.enumerated().map { index, phrase in
            let start = max(index == 0 ? 0 : result[index - 1].end, phrase.start - pad) * frame
            let end = index == result.count - 1 ? min(samples.count, (phrase.end + pad) * frame) : min(result[index + 1].start, phrase.end + pad) * frame
            return Phrase(start: start, end: end)
        }
    }

    /// Fraction of the clip inside its phrases.
    public static func coverage(_ phrases: [Phrase], total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(phrases.reduce(0) { $0 + $1.end - $1.start }) / Double(total)
    }
}

// MARK: - Paced recognizers

public struct PhraseOutcome: Sendable {
    public var text: String
    public var partialDelayMs: Int?       // phrase start → first non-empty partial (streaming engines)
    public var finalDelayMs: Int          // nominal phrase end → final text
    public var prefixRunMeanMs: Int?      // phrase-mode engines: cost of re-running on the growing phrase
    public var prefixRunMaxMs: Int?
    public init(text: String, partialDelayMs: Int?, finalDelayMs: Int, prefixRunMeanMs: Int? = nil, prefixRunMaxMs: Int? = nil) {
        self.text = text; self.partialDelayMs = partialDelayMs; self.finalDelayMs = finalDelayMs; self.prefixRunMeanMs = prefixRunMeanMs; self.prefixRunMaxMs = prefixRunMaxMs
    }
}

public protocol PacedRecognizer: Sendable {
    var name: String { get }
    var languages: Set<String> { get }
    var streaming: Bool { get }
    /// One phrase (16 kHz mono), fed at real-time pace from the call. `prefixEvery` is the re-run cadence
    /// for phrase-mode engines (0 disables prefix runs).
    func recognizePaced(_ samples: [Float], language: String, context: String?, prefixEvery: Double) async throws -> PhraseOutcome
    func residentBytes() async -> UInt64?
}
public extension PacedRecognizer { func residentBytes() async -> UInt64? { nil } }

/// Nemotron streaming through TranslateASR: chunks fed as their audio time arrives.
public struct NemotronPaced: PacedRecognizer {
    public let name: String
    public let languages: Set<String> = ["en", "es", "zh"]
    public let streaming = true
    let client: ASRClient
    let chunkMs: Int
    let languageNames: [String: String]   // corpus code → the checkpoint's prompt key (en-US, es-ES, zh-CN)
    public init(name: String = "nemotron", client: ASRClient, chunkMs: Int = 560, languageNames: [String: String] = ["en": "en-US", "es": "es-ES", "zh": "zh-CN"]) {
        self.name = name; self.client = client; self.chunkMs = chunkMs; self.languageNames = languageNames
    }

    public func recognizePaced(_ samples: [Float], language: String, context: String?, prefixEvery: Double) async throws -> PhraseOutcome {
        let rate = Double(client.sampleRate)
        let chunk = client.sampleRate * chunkMs / 1000
        let stream = try await client.startStream(language: languageNames[language] ?? language, chunkMs: chunkMs)
        let start = uptime()
        let duration = Double(samples.count) / rate
        var partial: Int?
        var offset = 0
        do {
            while offset < samples.count {
                let end = min(samples.count, offset + chunk)
                try await sleep(until: start + Double(end) / rate)
                let (text, _) = try await client.feed(stream: stream, samples: Array(samples[offset..<end]))
                if partial == nil, !isBlank(text) { partial = milliseconds(uptime() - start) }
                offset = end
            }
        } catch {
            // Close the session on every exit path (a feed error, or cancellation inside the pacing sleep): the helper holds at most four.
            _ = try? await client.finish(stream: stream)
            throw error
        }
        let final = try await client.finish(stream: stream)
        return PhraseOutcome(text: final.text, partialDelayMs: partial, finalDelayMs: milliseconds(uptime() - (start + duration)))
    }
    public func residentBytes() async -> UInt64? { (try? await client.stats())?.residentBytes }
}

/// Qwen3-ASR through TranslateASR in phrase mode: the final run starts when the phrase ends; before that,
/// the growing phrase is re-run every `prefixEvery` seconds the way a live caption would be refreshed.
public struct PhraseModePaced: PacedRecognizer {
    public let name: String
    public let languages: Set<String> = ["en", "es", "zh"]
    public let streaming = false
    let client: ASRClient
    let backend: String
    let languageNames: [String: String]
    let useContext: Bool
    public init(name: String, client: ASRClient, backend: String, languageNames: [String: String], useContext: Bool) {
        self.name = name; self.client = client; self.backend = backend; self.languageNames = languageNames; self.useContext = useContext
    }

    public func recognizePaced(_ samples: [Float], language: String, context: String?, prefixEvery: Double) async throws -> PhraseOutcome {
        let rate = Double(client.sampleRate)
        let start = uptime()
        let duration = Double(samples.count) / rate
        var runs: [Int] = []
        var partial: Int?
        if prefixEvery > 0 {
            var at = prefixEvery
            while at < duration - 0.3 {
                try await sleep(until: start + at)
                let prefix = Array(samples[0..<min(samples.count, Int(at * rate))])
                let began = uptime()
                let result = try await client.transcribe(backend: backend, samples: prefix, language: languageNames[language], context: useContext ? context : nil)
                runs.append(milliseconds(uptime() - began))
                if partial == nil, !isBlank(result.text) { partial = milliseconds(uptime() - start) }
                at += prefixEvery
            }
        }
        try await sleep(until: start + duration)
        let final = try await client.transcribe(backend: backend, samples: samples, language: languageNames[language], context: useContext ? context : nil)
        return PhraseOutcome(text: final.text, partialDelayMs: partial, finalDelayMs: milliseconds(uptime() - (start + duration)),
                             prefixRunMeanMs: runs.isEmpty ? nil : runs.reduce(0, +) / runs.count, prefixRunMaxMs: runs.max())
    }
    public func residentBytes() async -> UInt64? { (try? await client.stats())?.residentBytes }
}

/// Apple SpeechAnalyzer with volatile results, fed 320 ms buffers at real-time pace. The analyzer is
/// prepared and started before the clock runs, as the other engines' sessions are.
public struct ApplePaced: PacedRecognizer {
    public static let options = "reporting: volatileResults; one analyzer per phrase, prepared and started before the clock; 320 ms buffers"
    public let name = "apple-speech"
    public let languages: Set<String>
    public let streaming = true
    let locales: [String: String]
    public init(locales: [String: String]) { self.locales = locales; self.languages = Set(locales.keys) }

    public func recognizePaced(_ samples: [Float], language: String, context: String?, prefixEvery: Double) async throws -> PhraseOutcome {
        guard let localeID = locales[language] else { throw EngineClientProblem("No Apple locale for \(language).") }
        let transcriber = SpeechTranscriber(locale: Locale(identifier: localeID), transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw EngineClientProblem("Apple speech offers no audio format for \(localeID).") }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else { throw EngineClientProblem("No source format.") }
        let converter = source == target ? nil : AVAudioConverter(from: source, to: target)
        let (input, builder) = AsyncStream<AnalyzerInput>.makeStream()
        let collector = Task { () throws -> (finals: [String], partialAt: Double?, lastFinalAt: Double?) in
            var finals: [String] = []
            var partialAt: Double?
            var lastFinalAt: Double?
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if partialAt == nil, !isBlank(text) { partialAt = uptime() }
                if result.isFinal { finals.append(text); lastFinalAt = uptime() }
            }
            return (finals, partialAt, lastFinalAt)
        }
        do {
            try await analyzer.prepareToAnalyze(in: target)
            try await analyzer.start(inputSequence: input)
        } catch {
            builder.finish(); collector.cancel()
            throw EngineClientProblem("Apple speech could not start for \(localeID): \(error)")
        }
        let start = uptime()
        let duration = Double(samples.count) / 16_000
        do {
            let chunk = 16_000 * 32 / 100
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + chunk)
                try await sleep(until: start + Double(end) / 16_000)
                builder.yield(AnalyzerInput(buffer: try pcmBuffer(samples[offset..<end], source: source, converter: converter, target: target)))
                offset = end
            }
            builder.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            builder.finish(); collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw EngineClientProblem("Apple speech failed for \(localeID): \(error)")
        }
        let collected = try await collector.value
        let nominalEnd = start + duration
        return PhraseOutcome(text: collected.finals.joined(separator: " "), partialDelayMs: collected.partialAt.map { milliseconds($0 - start) },
                             finalDelayMs: milliseconds(max(collected.lastFinalAt ?? nominalEnd, nominalEnd) - nominalEnd))
    }

    func pcmBuffer(_ slice: ArraySlice<Float>, source: AVAudioFormat, converter: AVAudioConverter?, target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(slice.count)) else { throw EngineClientProblem("Buffer allocation failed.") }
        buffer.frameLength = AVAudioFrameCount(slice.count)
        slice.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: slice.count) }
        guard let converter else { return buffer }
        let ratio = target.sampleRate / source.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(slice.count) * ratio) + 64) else { throw EngineClientProblem("Buffer allocation failed.") }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return out
    }
}

// MARK: - Load

/// Continuous Qwen TTS on the engine while other passes run (plan §6.1, "under load"). The summary of a
/// pass doubles as the TTS "RTF while recognition runs" measure.
public actor LoadGenerator {
    public struct Summary: Codable, Sendable {
        public var syntheses: Int
        public var audioSeconds: Double
        public var generationMs: Int
        public var meanFirstAudioMs: Int
        public var realTimeFactor: Double
        public var errors: Int
        public var stoppedEarly: Bool       // the generator gave up before the pass ended, so part of the pass ran without load
        public var valid: Bool { errors == 0 && !stoppedEarly }
        public init(syntheses: Int, audioSeconds: Double, generationMs: Int, meanFirstAudioMs: Int, realTimeFactor: Double, errors: Int, stoppedEarly: Bool = false) {
            self.syntheses = syntheses; self.audioSeconds = audioSeconds; self.generationMs = generationMs; self.meanFirstAudioMs = meanFirstAudioMs
            self.realTimeFactor = realTimeFactor; self.errors = errors; self.stoppedEarly = stoppedEarly
        }
    }
    let engine: EngineClient
    let slot: String
    let text: String
    private var task: Task<Void, Never>?
    private var running = false
    private var syntheses = 0, generationMs = 0, firstAudioMs = 0, firstAudioCount = 0, errors = 0
    private var audioSeconds = 0.0
    private var stoppedEarly = false

    public init(engine: EngineClient, slot: String, text: String) { self.engine = engine; self.slot = slot; self.text = text }

    public func start() {
        guard task == nil else { return }
        syntheses = 0; generationMs = 0; firstAudioMs = 0; firstAudioCount = 0; errors = 0; audioSeconds = 0; stoppedEarly = false
        running = true
        task = Task { await self.loop() }
    }

    private func loop() async {
        while running {
            do {
                for try await event in await engine.synthesize(slot: slot, text: text) {
                    if case .done(let done) = event {
                        syntheses += 1; audioSeconds += done.audioSeconds; generationMs += done.generationMs
                        if done.firstAudioMs >= 0 { firstAudioMs += done.firstAudioMs; firstAudioCount += 1 }
                    }
                }
            } catch {
                errors += 1
                if errors > 5 { running = false; stoppedEarly = true }
            }
        }
    }

    public func stop() async -> Summary {
        running = false
        await task?.value
        task = nil
        return Summary(syntheses: syntheses, audioSeconds: (audioSeconds * 10).rounded() / 10, generationMs: generationMs,
                       meanFirstAudioMs: firstAudioCount > 0 ? firstAudioMs / firstAudioCount : 0,
                       realTimeFactor: audioSeconds > 0 ? (Double(generationMs) / 1000 / audioSeconds * 1000).rounded() / 1000 : 0, errors: errors, stoppedEarly: stoppedEarly)
    }
}
