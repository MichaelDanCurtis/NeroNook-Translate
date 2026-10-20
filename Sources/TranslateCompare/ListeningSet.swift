import Foundation
import TranslateEngineClient

/// TTS variant listening set (plan §6.1): every variant synthesizes the same sentences from the same
/// references, at each streaming interval, alone and while recognition streams. Clips are written under
/// blinded ids with one shared modification date; key.json and the receipt (variant, interval) go to a
/// `private/` folder apart from listening-sheet.md, which names only the speaker, the language and the
/// text so listeners can judge identity and pronunciation.
public enum ListeningSet {
    public struct Voice: Sendable {
        public let slot: String, name: String, reference: URL, transcript: String, language: String
        public init(slot: String, name: String, reference: URL, transcript: String, language: String) {
            self.slot = slot; self.name = name; self.reference = reference; self.transcript = transcript; self.language = language
        }
    }
    public struct Variant: Sendable {
        public let name: String, model: URL
        public init(name: String, model: URL) { self.name = name; self.model = model }
    }
    public struct Clip: Codable, Sendable {
        public var id: String
        public var variant: String
        public var voice: String
        public var voiceLanguage: String
        public var language: String
        public var sentence: Int
        public var text: String
        public var streamingInterval: Double
        public var underRecognition: Bool
        public var firstAudioMs: Int
        public var generationMs: Int
        public var audioSeconds: Double
        public var realTimeFactor: Double
        public var file: String
    }
    public struct VariantReceipt: Codable, Sendable {
        public var name: String
        public var model: String
        public var startupMs: Int
        public var loadMs: Int
        public var prepareMs: [String: Int]      // "voice→language": a slot is prepared per target language
        public var residentMBAfter: Double
        public var recognitionPassesDuringLoad: Int
        public var recognitionLoadError: String?  // set when the streaming loop broke, so "under recognition" clips had no load
    }
    public struct Receipt: Codable, Sendable {
        public var date: String
        public var machine: String
        public var variants: [VariantReceipt]
        public var clips: [Clip]
        public var notes: [String]
    }
    public struct Options {
        public var engine: URL
        public var variants: [Variant]
        public var voices: [Voice]
        public var sentences: [String: [String]]
        public var intervals: [Double]
        public var recognitionLoad: (client: ASRClient, samples: [Float])?
        public var out: URL
        public var log: URL?
        public init(engine: URL, variants: [Variant], voices: [Voice], sentences: [String: [String]], intervals: [Double], recognitionLoad: (client: ASRClient, samples: [Float])?, out: URL, log: URL?) {
            self.engine = engine; self.variants = variants; self.voices = voices; self.sentences = sentences; self.intervals = intervals; self.recognitionLoad = recognitionLoad; self.out = out; self.log = log
        }
    }

    /// The engine wants Qwen's language names; a slot is prepared for the language it will speak.
    public static let qwenNames = ["en": "English", "es": "Spanish", "zh": "Chinese", "ja": "Japanese", "ko": "Korean", "de": "German", "fr": "French", "ru": "Russian", "pt": "Portuguese", "it": "Italian"]

    /// Names, numbers, dates and a negation in every language, so pronunciation and meaning can be judged.
    public static let defaultSentences: [String: [String]] = [
        "en": ["Thanks for joining, Marisol. The delivery is confirmed for March twelfth, and the budget is fourteen thousand.",
               "I don't think we should sign before Tuesday; let's go through the numbers together first."],
        "es": ["Gracias por venir, Marisol. La entrega queda confirmada para el doce de marzo, y el presupuesto es de catorce mil.",
               "No creo que debamos firmar antes del martes; revisemos primero las cifras juntos."],
        "zh": ["谢谢你参加会议，玛丽索。交货日期确定为三月十二日，预算是一万四千。",
               "我觉得我们不应该在星期二之前签字；我们先一起把数字看一遍。"],
    ]

    public static func run(_ options: Options) async throws -> Receipt {
        let clipsFolder = options.out.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: clipsFolder, withIntermediateDirectories: true)
        var variants: [VariantReceipt] = []
        var clips: [Clip] = []
        var used = Set<String>()
        func blindID() -> String {
            while true {
                let id = String(format: "%06x", Int.random(in: 0..<0xFF_FFFF))
                if !used.contains(id) { used.insert(id); return id }
            }
        }
        func record(_ variant: Variant, _ voice: Voice, language: String, sentence: Int, text: String, interval: Double, underRecognition: Bool, samples: [Float], done: SynthesisDone) throws {
            let id = blindID()
            try AudioDecoding.writeWAV(samples, sampleRate: Double(done.sampleRate), to: clipsFolder.appendingPathComponent(id + ".wav"))
            clips.append(Clip(id: id, variant: variant.name, voice: voice.name, voiceLanguage: voice.language, language: language, sentence: sentence, text: text, streamingInterval: interval,
                              underRecognition: underRecognition, firstAudioMs: done.firstAudioMs, generationMs: done.generationMs, audioSeconds: (done.audioSeconds * 100).rounded() / 100,
                              realTimeFactor: (done.realTimeFactor * 1000).rounded() / 1000, file: "clips/\(id).wav"))
        }
        let languages = options.sentences.keys.sorted()

        for variant in options.variants {
            print("variant \(variant.name): \(variant.model.lastPathComponent)")
            let engine = try await EngineClient.launch(engine: options.engine, model: variant.model, log: options.log)
            var prepareMs: [String: Int] = [:]
            var passes = 0
            var loadError: String?
            /// Prepares the voice's slot for one target language and warms it once, so measured first-audio
            /// numbers are warm (plan §6.1).
            func prepare(_ voice: Voice, for language: String, label: String = "") async throws {
                guard let name = qwenNames[language] else { throw EngineClientProblem("No Qwen language name for \(language).") }
                let prepared = try await engine.prepareVoice(slot: voice.slot, reference: voice.reference, transcript: voice.transcript, language: name)
                prepareMs["\(voice.name)→\(language)\(label)"] = prepared.prepareMs
                _ = try await synthesize(engine, slot: voice.slot, text: options.sentences[language]?.first ?? "Hello.", interval: 0.32)
            }
            do {
                var count = 0
                for voice in options.voices {
                    for language in languages {
                        try await prepare(voice, for: language)
                        for interval in options.intervals {
                            for (index, text) in (options.sentences[language] ?? []).enumerated() {
                                let (samples, done) = try await synthesize(engine, slot: voice.slot, text: text, interval: interval)
                                try record(variant, voice, language: language, sentence: index + 1, text: text, interval: interval, underRecognition: false, samples: samples, done: done)
                                count += 1
                            }
                        }
                    }
                }
                print("  alone: \(count) clips over \(options.intervals.count) interval(s)")
                if let load = options.recognitionLoad {
                    let paced = NemotronPaced(client: load.client)
                    let streaming = Task { () -> (passes: Int, error: String?) in
                        var passes = 0
                        while !Task.isCancelled {
                            do { _ = try await paced.recognizePaced(load.samples, language: "en", context: nil, prefixEvery: 0); passes += 1 }
                            catch is CancellationError { break }
                            catch { return (passes, "\(error)") }
                        }
                        return (passes, nil)
                    }
                    count = 0
                    for voice in options.voices {
                        for language in languages {
                            guard let text = options.sentences[language]?.first else { continue }
                            try await prepare(voice, for: language, label: " (under recognition)")
                            let (samples, done) = try await synthesize(engine, slot: voice.slot, text: text, interval: 0.32)
                            try record(variant, voice, language: language, sentence: 1, text: text, interval: 0.32, underRecognition: true, samples: samples, done: done)
                            count += 1
                        }
                    }
                    streaming.cancel()
                    let outcome = await streaming.value
                    passes = outcome.passes; loadError = outcome.error
                    print("  while recognition streams: \(count) clips, \(passes) recognition passes" + (loadError.map { " · load loop failed: \($0)" } ?? ""))
                }
            } catch { await engine.shutdown(); throw error }
            let stats = try? await engine.stats()
            variants.append(VariantReceipt(name: variant.name, model: variant.model.lastPathComponent, startupMs: engine.startupMs, loadMs: engine.loadMs, prepareMs: prepareMs,
                                           residentMBAfter: stats.map { (Double($0.residentBytes) / 1_048_576 * 10).rounded() / 10 } ?? 0, recognitionPassesDuringLoad: passes,
                                           recognitionLoadError: loadError))
            await engine.shutdown()
        }
        // One modification date for every clip, so file dates cannot reveal which variant made which clip.
        let stamp = Date()
        for clip in clips { try? FileManager.default.setAttributes([.modificationDate: stamp, .creationDate: stamp], ofItemAtPath: options.out.appendingPathComponent(clip.file).path) }

        var machine = "unknown"; var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0 { var buffer = [CChar](repeating: 0, count: size); if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 { machine = String(cString: buffer) } }
        let receipt = Receipt(date: ISO8601DateFormatter().string(from: Date()), machine: machine, variants: variants, clips: clips,
                              notes: ["Clip ids are blinded; private/key.json and private/listening-receipt.json map them to variant and interval and must stay away from listeners.",
                                      "First audio and RTF are warm (one synthesis per slot before measuring). 'Under recognition' clips were made while Nemotron streamed a clip in a loop.",
                                      "Identity ratings only mean something with the speakers' own reference recordings; synthetic fixtures check the plumbing."])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let privateFolder = options.out.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(receipt).write(to: privateFolder.appendingPathComponent("listening-receipt.json"))
        try encoder.encode(clips).write(to: privateFolder.appendingPathComponent("key.json"))
        try sheet(clips).write(to: options.out.appendingPathComponent("listening-sheet.md"), atomically: true, encoding: .utf8)
        try summary(receipt).write(to: options.out.appendingPathComponent("tts-summary.md"), atomically: true, encoding: .utf8)
        print(summary(receipt))
        return receipt
    }

    static func synthesize(_ engine: EngineClient, slot: String, text: String, interval: Double) async throws -> ([Float], SynthesisDone) {
        var samples: [Float] = []
        for try await event in await engine.synthesize(slot: slot, text: text, streamingInterval: interval) {
            switch event {
            case .audio(let data, _): samples += data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            case .done(let done): return (samples, done)
            }
        }
        throw EngineClientProblem("Synthesis ended without a done frame.")
    }

    static func sheet(_ clips: [Clip]) -> String {
        var md = "# Listening sheet\n\nPlay each clip from `clips/`. Identity: does it sound like the named speaker (1–5)? Pronunciation: rated by a speaker of the clip's language (1–5). Note accent, wrong words, artefacts.\n\n| Clip | Speaker | Language | Text | Identity | Pronunciation | Notes |\n| --- | --- | --- | --- | --- | --- | --- |\n"
        for clip in clips.shuffled() {
            md += "| \(clip.id) | \(clip.voice) | \(clip.language) | \(clip.text) |  |  |  |\n"
        }
        return md
    }

    static func summary(_ receipt: Receipt) -> String {
        var md = "# TTS variants · \(receipt.date) · \(receipt.machine)\n\n| Variant | Startup ms | Load ms | Prepare ms per voice and language | Resident MB | Recognition load |\n| --- | --- | --- | --- | --- | --- |\n"
        for v in receipt.variants {
            md += "| \(v.name) | \(v.startupMs) | \(v.loadMs) | \(v.prepareMs.keys.sorted().map { "\($0) \(v.prepareMs[$0]!)" }.joined(separator: ", ")) | \(v.residentMBAfter) | \(v.recognitionLoadError.map { "failed: \($0)" } ?? "\(v.recognitionPassesDuringLoad) passes") |\n"
        }
        md += "\n| Variant | Interval s | Under recognition | Clips | Mean first audio ms | Max first audio ms | Mean RTF | Max RTF |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n"
        let groups = Dictionary(grouping: receipt.clips) { "\($0.variant)|\($0.streamingInterval)|\($0.underRecognition ? 1 : 0)" }
        for key in groups.keys.sorted() {
            let rows = groups[key]!
            let first = rows.map(\.firstAudioMs), rtf = rows.map(\.realTimeFactor)
            md += "| \(rows[0].variant) | \(rows[0].streamingInterval) | \(rows[0].underRecognition ? "yes" : "no") | \(rows.count) | \(first.reduce(0, +) / rows.count) | \(first.max() ?? 0) | \(String(format: "%.3f", rtf.reduce(0, +) / Double(rows.count))) | \(String(format: "%.3f", rtf.max() ?? 0)) |\n"
        }
        md += "\nNotes:\n" + receipt.notes.map { "- \($0)" }.joined(separator: "\n") + "\n"
        return md
    }
}
