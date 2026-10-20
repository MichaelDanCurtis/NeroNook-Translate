import Darwin
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import MLXLMCommon

// TranslateEngine: one resident Qwen3-TTS Base model, one prepared reference conditioning per voice
// slot, one generation at a time. Requests arrive as frames on stdin; replies leave on a private
// duplicate of stdout. The library prints diagnostics to stdout, so stdout itself is pointed at
// stderr before anything loads (plan §2.1).
//
// Cancellation is finish-and-discard (D‑8): `cancel` stops forwarding a request's audio while its
// generation runs to completion, and `done` reports how long the discarded tail took. The engine
// never leaves a generation early itself either: an engine-side limit is noted and the library loop
// is drained, so the model's streaming decoder is entered once per generation, always.

let outputFD = dup(STDOUT_FILENO)
_ = fcntl(outputFD, F_SETNOSIGPIPE, 1)   // a closed reader surfaces as a write error, not a signal
let outputHandle = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
dup2(STDERR_FILENO, STDOUT_FILENO)
setvbuf(stdout, nil, _IONBF, 0)

let outputLock = NSLock()
func send(_ header: [String: Any], payload: Data = Data()) {
    outputLock.lock(); defer { outputLock.unlock() }
    do { try outputHandle.write(contentsOf: try Frame.encode(header, payload: payload)) } catch { exit(1) }
}
/// Request errors carry the request's id so the client fails only that request. An empty id means
/// the request itself was malformed; the client ignores it.
func sendError(_ id: String?, _ message: String) {
    send(["type": "error", "id": id ?? "", "message": String(message.prefix(240))])
}
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func milliseconds(since start: Double) -> Int { Int(((now() - start) * 1000).rounded()) }

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

/// Synthesis requests the reader has seen, and which of them were cancelled. Shared between the reader
/// thread (registers and cancels) and the executor (consults and forgets). Only known ids are recorded,
/// so a stray cancel cannot grow the table.
final class Requests {
    private let lock = NSLock()
    private var known: Set<String> = []
    private var cancelledAt: [String: Double] = [:]
    func register(_ id: String) { lock.lock(); known.insert(id); lock.unlock() }
    func cancel(_ id: String) { lock.lock(); if known.contains(id) { cancelledAt[id] = now() }; lock.unlock() }
    func cancellation(of id: String) -> Double? { lock.lock(); defer { lock.unlock() }; return cancelledAt[id] }
    func forget(_ id: String) { lock.lock(); known.remove(id); cancelledAt[id] = nil; lock.unlock() }
}

struct Limits {
    static let maxTextBytes = 2048
    static let minReferenceSeconds = 3.0
    static let maxReferenceSeconds = 30.0
    static let generationSeconds = 150.0
    static let maxAudioSeconds = 180.0
    static let maxTokens = 1800
    static let languages: Set<String> = ["English", "Chinese", "Japanese", "Korean", "German", "French", "Russian", "Portuguese", "Spanish", "Italian"]
}

// MARK: - Startup

let arguments = CommandLine.arguments
guard let modelIndex = arguments.firstIndex(of: "--model"), arguments.indices.contains(modelIndex + 1) else {
    sendError(nil, "Usage: TranslateEngine --model <checkpoint directory>")
    exit(2)
}
let modelDirectory = URL(fileURLWithPath: arguments[modelIndex + 1])
let loadStarted = now()
let model: Qwen3TTSModel
do {
    let configData = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
    let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
    guard config?["tts_model_type"] as? String == "base" else { throw EngineProblem("TranslateEngine needs a Qwen3-TTS Base checkpoint.") }
    model = try await Qwen3TTSModel.fromModelDirectory(modelDirectory)
    MLX.Memory.cacheLimit = 128 * 1024 * 1024
} catch {
    sendError(nil, "Model load failed: \(error)")
    exit(1)
}
send(["type": "ready", "version": 1, "sampleRate": model.sampleRate, "loadMs": milliseconds(since: loadStarted), "residentBytes": residentBytes()])

// MARK: - Reader thread

nonisolated(unsafe) let requests = Requests()
nonisolated(unsafe) let (queue, queueSink) = AsyncStream<Frame.Message>.makeStream()

let reader = Thread {
    let frames = Frame.Reader()
    var bytes = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(STDIN_FILENO, &bytes, bytes.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { queueSink.finish(); return }
        do {
            for message in try frames.feed(Data(bytes[0..<n])) {
                switch message.type {
                case "cancel":
                    if let id = message.header["id"] as? String { requests.cancel(id) }
                case "stats":
                    send(["type": "stats", "id": message.header["id"] as? String ?? "", "residentBytes": residentBytes(),
                          "activeBytes": MLX.Memory.activeMemory, "peakBytes": MLX.Memory.peakMemory, "cacheBytes": MLX.Memory.cacheMemory])
                case "shutdown":
                    queueSink.finish()
                case "synthesize":
                    if let id = message.header["id"] as? String { requests.register(id) }
                    queueSink.yield(message)
                default:
                    queueSink.yield(message)
                }
            }
        } catch {
            sendError(nil, "Protocol error: \(error)")
            exit(1)
        }
    }
}
reader.start()

// MARK: - Executor

nonisolated(unsafe) var conditionings: [String: Qwen3TTSModel.Qwen3TTSReferenceConditioning] = [:]
// The library caches the last reference context keyed by the MLXArray's object identity. A freed
// array's address can be reused by the next one, which would silently hand a new voice the previous
// voice's context. Keeping every slot's reference array alive makes identities unique for the process.
nonisolated(unsafe) var references: [String: MLXArray] = [:]

func prepareVoice(_ message: Frame.Message) {
    let id = message.header["id"] as? String
    do {
        guard let slot = message.header["slot"] as? String, ["local", "remote", "generic"].contains(slot),
              let transcript = message.header["transcript"] as? String, !transcript.isEmpty, transcript.utf8.count <= Limits.maxTextBytes,
              let language = message.header["language"] as? String, Limits.languages.contains(language),
              let sampleRate = message.header["sampleRate"] as? Int, sampleRate == model.sampleRate,
              message.payload.count % 4 == 0 else { throw EngineProblem("Invalid prepareVoice request.") }
        let samples = message.payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let seconds = Double(samples.count) / Double(sampleRate)
        guard seconds >= Limits.minReferenceSeconds, seconds <= Limits.maxReferenceSeconds, samples.allSatisfy({ $0.isFinite && abs($0) <= 4 }) else {
            throw EngineProblem("Reference must be 3–30 seconds of finite audio.")
        }
        let started = now()
        let audio = MLXArray(samples)
        let conditioning = try model.prepareReferenceConditioning(refAudio: audio, refText: transcript, language: language)
        if let embedding = conditioning.speakerEmbedding { eval(embedding, conditioning.referenceSpeechCodes, conditioning.referenceTextTokenIDs) }
        else { eval(conditioning.referenceSpeechCodes, conditioning.referenceTextTokenIDs) }
        guard conditioning.codecLanguageID != nil else { throw EngineProblem("The checkpoint has no language id for \(language).") }
        conditionings[slot] = conditioning
        references[slot] = audio
        send(["type": "voiceReady", "id": id ?? "", "slot": slot, "seconds": seconds, "prepareMs": milliseconds(since: started),
              "language": conditioning.resolvedLanguage, "residentBytes": residentBytes()])
    } catch {
        sendError(id, "prepareVoice failed: \(error)")
    }
}

func synthesize(_ message: Frame.Message) async {
    guard let id = message.header["id"] as? String else { sendError(nil, "synthesize needs an id."); return }
    defer { requests.forget(id) }
    do {
        guard let slot = message.header["slot"] as? String, let conditioning = conditionings[slot] else { throw EngineProblem("Voice slot is not prepared.") }
        guard let text = message.header["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= Limits.maxTextBytes else {
            throw EngineProblem("Invalid text.")
        }
        let interval = message.header["streamingInterval"] as? Double ?? 0.32
        guard interval.isFinite, (0.16...1).contains(interval) else { throw EngineProblem("Invalid streaming interval.") }
        let maxTokens = min(max(message.header["maxTokens"] as? Int ?? Limits.maxTokens, 16), Limits.maxTokens)

        // A cancel that arrives before the generation starts drops the unit at once (plan §2.4).
        if let cancelledAt = requests.cancellation(of: id) {
            send(["type": "done", "id": id, "frames": 0, "forwardedFrames": 0, "sampleRate": model.sampleRate, "firstAudioMs": -1,
                  "generationMs": 0, "discarded": true, "wastedMs": milliseconds(since: cancelledAt)])
            return
        }

        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.9, topP: 1, topK: 50, repetitionPenalty: 1.1)
        let started = now()
        var firstAudioMs: Int?
        var sequence = 0
        var frames = 0
        var forwardedFrames = 0
        var abort: EngineProblem?
        for try await event in model.generateStream(text: text, conditioning: conditioning, generationParameters: parameters, streamingInterval: interval) {
            guard case .audio(let chunk) = event else { continue }
            // An engine-side limit stops forwarding but never breaks out of the library's loop: the
            // generation is drained to its end so the decoder state is left exactly as the library leaves it.
            if abort == nil, now() - started >= Limits.generationSeconds { abort = EngineProblem("Generation timed out.") }
            let floats = chunk.asArray(Float.self)
            if abort == nil, !floats.allSatisfy(\.isFinite) { abort = EngineProblem("Non-finite audio.") }
            frames += floats.count
            if abort == nil, frames > Int(Limits.maxAudioSeconds) * model.sampleRate { abort = EngineProblem("Audio exceeds three minutes.") }
            if firstAudioMs == nil { firstAudioMs = milliseconds(since: started) }
            guard abort == nil, requests.cancellation(of: id) == nil else { continue }
            send(["type": "audio", "id": id, "seq": sequence, "sampleRate": model.sampleRate], payload: floats.withUnsafeBytes { Data($0) })
            sequence += 1
            forwardedFrames += floats.count
        }
        if let abort { throw abort }
        guard frames > 0 else { throw EngineProblem("No audio was generated.") }
        var done: [String: Any] = ["type": "done", "id": id, "frames": frames, "forwardedFrames": forwardedFrames, "sampleRate": model.sampleRate,
                                   "firstAudioMs": firstAudioMs ?? -1, "generationMs": milliseconds(since: started), "discarded": false]
        if let cancelledAt = requests.cancellation(of: id) {
            done["discarded"] = true
            done["wastedMs"] = milliseconds(since: cancelledAt)
        }
        send(done)
    } catch {
        sendError(id, "synthesize failed: \(error)")
    }
}

for await message in queue {
    switch message.type {
    case "prepareVoice": prepareVoice(message)
    case "synthesize": await synthesize(message)
    case "ping": send(["type": "pong", "id": message.header["id"] as? String ?? ""])
    default: sendError(message.header["id"] as? String, "Unknown request type.")
    }
}
exit(0)
