import Darwin
import EngineProtocol
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT

// TranslateASR: the recognition helper. It runs apart from TranslateEngine so captions never wait
// behind speech generation (plan §2.3). It hosts up to one of each backend at a time:
//   nemotron  Nemotron 3.5 streaming RNN-T (true incremental sessions)
//   qwen3asr  Qwen3-ASR (phrase mode: a complete clip in, text out; `context` biases names)
//   aligner   Qwen3-ForcedAligner (word timestamps for a known text)
// Same framing as the engine (docs/PROTOCOL.md). Audio payloads are Float32 LE mono at 16 kHz.

let outputFD = dup(STDOUT_FILENO)
_ = fcntl(outputFD, F_SETNOSIGPIPE, 1)
let outputHandle = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
dup2(STDERR_FILENO, STDOUT_FILENO)
setvbuf(stdout, nil, _IONBF, 0)

let outputLock = NSLock()
func send(_ header: [String: Any], payload: Data = Data()) {
    outputLock.lock(); defer { outputLock.unlock() }
    let frame: Data
    do { frame = try Frame.encode(header, payload: payload) } catch {
        // A reply too large to frame becomes an error for its request; the helper stays up.
        let fallback: [String: Any] = ["type": "error", "id": header["id"] as? String ?? "", "message": "Reply exceeds the frame limit."]
        guard let data = try? Frame.encode(fallback) else { exit(1) }
        do { try outputHandle.write(contentsOf: data) } catch { exit(1) }
        return
    }
    do { try outputHandle.write(contentsOf: frame) } catch { exit(1) }
}
func sendError(_ id: String?, _ message: String) { send(["type": "error", "id": id ?? "", "message": String(message.prefix(240))]) }
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

struct Limits {
    static let sampleRate = 16_000
    static let maxClipSeconds = 600.0
    static let maxTextBytes = 4096
    static let qwenLanguages: Set<String> = ["English", "Chinese", "Japanese", "Korean", "German", "French", "Russian", "Portuguese", "Spanish", "Italian", "auto"]
}

func samples(from payload: Data) throws -> [Float] {
    guard payload.count % 4 == 0, payload.count > 0 else { throw EngineProblem("Audio payload must be Float32 samples.") }
    let floats = payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard Double(floats.count) / Double(Limits.sampleRate) <= Limits.maxClipSeconds, floats.allSatisfy({ $0.isFinite && abs($0) <= 4 }) else {
        throw EngineProblem("Audio must be finite and at most ten minutes.")
    }
    return floats
}

MLX.Memory.cacheLimit = 128 * 1024 * 1024

// `--prepare <backend> <dir>`: a one-time, unsandboxed load so the library can write any derived file it
// needs next to the checkpoint (Qwen3-ASR generates tokenizer.json from vocab.json and merges.txt).
// At runtime the helper runs with the model folder read-only and this never happens.
if let index = CommandLine.arguments.firstIndex(of: "--prepare"), CommandLine.arguments.indices.contains(index + 2) {
    let backend = CommandLine.arguments[index + 1], directory = URL(fileURLWithPath: CommandLine.arguments[index + 2])
    do {
        switch backend {
        case "nemotron": _ = try NemotronASRModel.fromDirectory(directory)
        case "qwen3asr": _ = try await Qwen3ASRModel.fromModelDirectory(directory)
        case "aligner": _ = try await Qwen3ForcedAlignerModel.fromModelDirectory(directory)
        default: FileHandle.standardError.write(Data("Unknown backend\n".utf8)); exit(2)
        }
        FileHandle.standardError.write(Data("prepared \(backend) at \(directory.lastPathComponent)\n".utf8))
        exit(0)
    } catch { FileHandle.standardError.write(Data("prepare failed: \(error)\n".utf8)); exit(1) }
}

send(["type": "ready", "version": 1, "sampleRate": Limits.sampleRate, "residentBytes": residentBytes()])

// MARK: - Reader thread

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
                case "stats":
                    send(["type": "stats", "id": message.header["id"] as? String ?? "", "residentBytes": residentBytes(),
                          "activeBytes": MLX.Memory.activeMemory, "peakBytes": MLX.Memory.peakMemory, "cacheBytes": MLX.Memory.cacheMemory])
                case "shutdown": queueSink.finish()
                default: queueSink.yield(message)
                }
            }
        } catch { sendError(nil, "Protocol error: \(error)"); exit(1) }
    }
}
reader.start()

// MARK: - Backends

nonisolated(unsafe) var nemotron: NemotronASRModel?
nonisolated(unsafe) var qwen: Qwen3ASRModel?
nonisolated(unsafe) var aligner: Qwen3ForcedAlignerModel?
nonisolated(unsafe) var streams: [String: NemotronASRStreamSession] = [:]
nonisolated(unsafe) var nemotronLanguages: Set<String> = []   // the checkpoint's prompt dictionary keys (en-US, es-ES, zh-CN, …)

/// The language keys Nemotron was trained with, from config.json; a code outside them would silently
/// fall back to auto-detection in the runtime, so the helper rejects it instead.
func nemotronPromptKeys(_ directory: URL) -> Set<String> {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
          let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let prompt = config["prompt"] as? [String: Any], let dictionary = prompt["prompt_dictionary"] as? [String: Any] else { return [] }
    return Set(dictionary.keys)
}
func checkNemotronLanguage(_ language: String?) throws {
    guard let language, language != "auto" else { return }
    guard nemotronLanguages.contains(language) else { throw EngineProblem("Nemotron has no prompt for \(language); use one of its keys (en-US, es-ES, es-US, zh-CN, …) or auto.") }
}

func load(_ message: Frame.Message) async {
    let id = message.header["id"] as? String
    do {
        guard let backend = message.header["backend"] as? String, let path = message.header["model"] as? String else { throw EngineProblem("load needs backend and model.") }
        let directory = URL(fileURLWithPath: path)
        let started = now()
        switch backend {
        case "nemotron": nemotron = try NemotronASRModel.fromDirectory(directory); nemotronLanguages = nemotronPromptKeys(directory)
        case "qwen3asr": qwen = try await Qwen3ASRModel.fromModelDirectory(directory)
        case "aligner": aligner = try await Qwen3ForcedAlignerModel.fromModelDirectory(directory)
        default: throw EngineProblem("Unknown backend.")
        }
        send(["type": "loaded", "id": id ?? "", "backend": backend, "sampleRate": Limits.sampleRate, "loadMs": milliseconds(since: started), "residentBytes": residentBytes()])
    } catch { sendError(id, "load failed: \(error)") }
}

func segmentList(_ raw: [[String: Any]]?) -> [[String: Any]] {
    (raw ?? []).compactMap { segment in
        guard let text = segment["text"] as? String else { return nil }
        return ["text": text, "start": (segment["start"] as? Double) ?? -1, "end": (segment["end"] as? Double) ?? -1]
    }
}

/// Phrase-mode recognition of a complete clip.
func transcribe(_ message: Frame.Message) {
    let id = message.header["id"] as? String
    do {
        guard let backend = message.header["backend"] as? String else { throw EngineProblem("transcribe needs a backend.") }
        let audio = try samples(from: message.payload)
        let language = message.header["language"] as? String
        let context = message.header["context"] as? String ?? ""
        guard context.utf8.count <= Limits.maxTextBytes else { throw EngineProblem("Context is too long.") }
        let started = now()
        var text = ""
        var detected: String?
        var segments: [[String: Any]] = []
        switch backend {
        case "nemotron":
            guard let nemotron else { throw EngineProblem("Nemotron is not loaded.") }
            try checkNemotronLanguage(language)
            let output = nemotron.generate(audio: MLXArray(audio), generationParameters: STTGenerateParameters(language: language))
            text = output.text; detected = output.language; segments = segmentList(output.segments)
        case "qwen3asr":
            guard let qwen else { throw EngineProblem("Qwen3-ASR is not loaded.") }
            if let language { guard Limits.qwenLanguages.contains(language) else { throw EngineProblem("Unsupported language name.") } }
            let output = qwen.generate(audio: MLXArray(audio), context: context, language: language == "auto" ? nil : language)
            text = output.text; detected = output.language; segments = segmentList(output.segments)
        default: throw EngineProblem("Backend does not transcribe.")
        }
        guard text.utf8.count <= 48 * 1024 else { throw EngineProblem("Transcript is too long.") }
        // Segments repeat the text; drop them rather than exceed the header limit on a long recording.
        let segmentBytes = segments.reduce(0) { $0 + (($1["text"] as? String)?.utf8.count ?? 0) + 48 }
        if text.utf8.count + segmentBytes > 56 * 1024 { segments = [] }
        var reply: [String: Any] = ["type": "transcript", "id": id ?? "", "backend": backend, "text": text, "ms": milliseconds(since: started),
                                    "audioSeconds": Double(audio.count) / Double(Limits.sampleRate), "segments": segments]
        if let detected { reply["language"] = detected }
        send(reply)
    } catch { sendError(id, "transcribe failed: \(error)") }
}

/// Nemotron incremental session: streamStart → streamAudio… → streamFinish.
func streamStart(_ message: Frame.Message) {
    let id = message.header["id"] as? String
    do {
        guard let id, let nemotron else { throw EngineProblem("Nemotron is not loaded or the request has no id.") }
        let chunkMs = message.header["chunkMs"] as? Int ?? 560
        guard (80...2000).contains(chunkMs), streams.count < 4 else { throw EngineProblem("Invalid chunk size or too many sessions.") }
        let language = message.header["language"] as? String ?? "auto"
        try checkNemotronLanguage(language)
        streams[id] = nemotron.makeStreamSession(language: language, chunkMs: chunkMs)
        send(["type": "streamReady", "id": id, "chunkMs": chunkMs])
    } catch { sendError(id, "streamStart failed: \(error)") }
}

func streamAudio(_ message: Frame.Message) {
    let id = message.header["id"] as? String
    do {
        guard let id, let session = streams[id] else { throw EngineProblem("No such stream.") }
        let audio = try samples(from: message.payload)
        let started = now()
        _ = session.step(audio)
        send(["type": "partial", "id": id, "text": session.text, "ms": milliseconds(since: started)])
    } catch { sendError(id, "streamAudio failed: \(error)") }
}

func streamFinish(_ message: Frame.Message) {
    let id = message.header["id"] as? String
    do {
        guard let id, let session = streams.removeValue(forKey: id) else { throw EngineProblem("No such stream.") }
        let started = now()
        _ = session.finish()
        send(["type": "final", "id": id, "text": session.text, "ms": milliseconds(since: started), "segments": segmentList(session.segments)])
    } catch { sendError(id, "streamFinish failed: \(error)") }
}

func align(_ message: Frame.Message) {
    let id = message.header["id"] as? String
    do {
        guard let aligner else { throw EngineProblem("The aligner is not loaded.") }
        guard let text = message.header["text"] as? String, !text.isEmpty, text.utf8.count <= Limits.maxTextBytes else { throw EngineProblem("align needs text.") }
        let audio = try samples(from: message.payload)
        let started = now()
        let result = aligner.generate(audio: MLXArray(audio), text: text, language: message.header["language"] as? String ?? "English")
        let items: [[String: Any]] = result.items.map { ["text": $0.text, "start": $0.startTime, "end": $0.endTime] }
        send(["type": "alignment", "id": id ?? "", "items": items, "ms": milliseconds(since: started)])
    } catch { sendError(id, "align failed: \(error)") }
}

for await message in queue {
    switch message.type {
    case "load": await load(message)
    case "transcribe": transcribe(message)
    case "streamStart": streamStart(message)
    case "streamAudio": streamAudio(message)
    case "streamFinish": streamFinish(message)
    case "align": align(message)
    case "ping": send(["type": "pong", "id": message.header["id"] as? String ?? ""])
    default: sendError(message.header["id"] as? String, "Unknown request type.")
    }
}
exit(0)
