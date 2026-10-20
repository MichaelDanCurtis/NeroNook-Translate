import Foundation
import TranslateEngineClient

/// Runs every candidate on the same corpus and writes one receipt (plan §6.1). With a load generator, every
/// pass runs twice: alone, then while Qwen TTS synthesizes continuously in the engine.
public enum CompareRunner {
    public struct RecognitionRow: Codable, Sendable {
        public var recognizer: String
        public var item: String
        public var language: String
        public var kind: String
        public var underLoad: Bool
        public var audioSeconds: Double
        public var ms: Int
        public var realTimeFactor: Double
        public var errorRate: ErrorRate
        public var checksPassed: Int
        public var checksTotal: Int
        public var byCategory: [String: String]       // "passed/total"
        public var hypothesis: String
        public var detectedLanguage: String?
        public var residentBytesAfter: UInt64?
        public var error: String?
    }
    public struct TranslationRow: Codable, Sendable {
        public var translator: String
        public var item: String
        public var from: String
        public var to: String
        public var line: Int
        public var underLoad: Bool
        public var source: String
        public var output: String
        public var ms: Int
        public var firstTokenMs: Int?
        public var withContext: Bool
        public var error: String?
    }
    public struct PhraseResult: Codable, Sendable {
        public var index: Int
        public var startSeconds: Double
        public var seconds: Double
        public var partialDelayMs: Int?
        public var finalDelayMs: Int
        public var prefixRunMeanMs: Int?
        public var prefixRunMaxMs: Int?
        public var text: String
    }
    public struct PacedRow: Codable, Sendable {
        public var recognizer: String
        public var item: String
        public var language: String
        public var kind: String
        public var underLoad: Bool
        public var audioSeconds: Double
        public var phrases: [PhraseResult]
        public var errorRate: ErrorRate
        public var checksPassed: Int
        public var checksTotal: Int
        public var meanFinalDelayMs: Int
        public var p90FinalDelayMs: Int
        public var maxFinalDelayMs: Int
        public var meanPartialDelayMs: Int?
        public var prefixRunMeanMs: Int?
        public var prefixRunMaxMs: Int?
        public var coverage: Double            // fraction of the recording inside the fed phrases
        public var residentBytesAfter: UInt64?
        public var error: String?
    }
    public struct Receipt: Codable, Sendable {
        public var date: String
        public var machine: String
        public var build: [String: String]      // git head, SDK stamp
        public var settings: [String: String]   // chunk size, context window, locales, options
        public var models: [String: String]     // candidate → checkpoint folder
        public var corpus: String
        public var items: [String]
        public var recognition: [RecognitionRow]
        public var translation: [TranslationRow]
        public var paced: [PacedRow]
        public var load: [String: LoadGenerator.Summary]
        public var resources: [String: PassResources]   // per pass: CPU, footprint and MLX counters per process, GPU utilization
        public var notes: [String]
    }

    public struct Options {
        public var items: [CorpusItem]
        public var recognizers: [any Recognizer]
        public var pacedRecognizers: [any PacedRecognizer]
        public var translators: [any Translator]
        public var pairs: [(from: String, to: String)]
        public var contextWindow = 2
        public var prefixEvery = 1.0
        public var load: LoadGenerator?
        public var settings: [String: String] = [:]
        public var models: [String: String] = [:]
        public var monitors: [ResourceMonitor] = []
        public var out: URL
        public var corpusLabel: String
        public init(items: [CorpusItem], recognizers: [any Recognizer], pacedRecognizers: [any PacedRecognizer] = [], translators: [any Translator],
                    pairs: [(from: String, to: String)], load: LoadGenerator? = nil, prefixEvery: Double = 1, settings: [String: String] = [:], models: [String: String] = [:],
                    monitors: [ResourceMonitor] = [], out: URL, corpusLabel: String) {
            self.items = items; self.recognizers = recognizers; self.pacedRecognizers = pacedRecognizers; self.translators = translators
            self.pairs = pairs; self.load = load; self.prefixEvery = prefixEvery; self.settings = settings; self.models = models; self.monitors = monitors
            self.out = out; self.corpusLabel = corpusLabel
        }
    }

    /// Every row is also appended to `rows.jsonl` the moment it exists, so a run that dies keeps what it measured.
    final class RowLog: @unchecked Sendable {
        private let handle: FileHandle?
        private let encoder = JSONEncoder()
        init(_ url: URL) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            encoder.outputFormatting = [.sortedKeys]
        }
        func write<T: Encodable>(_ kind: String, _ row: T) {
            guard let handle, let data = try? encoder.encode(row) else { return }
            try? handle.write(contentsOf: Data("{\"kind\":\"\(kind)\",\"row\":".utf8) + data + Data("}\n".utf8))
        }
    }

    static func buildInfo() -> [String: String] {
        var info: [String: String] = ["sdkStamp": BuildStamp.programSDKVersion() ?? "unknown"]
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path, "rev-parse", "--short", "HEAD"]
        let pipe = Pipe(); git.standardOutput = pipe; git.standardError = FileHandle.nullDevice
        if (try? git.run()) != nil {
            git.waitUntilExit()
            if let head = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty { info["gitHead"] = head + " (plus uncommitted changes unless the receipt says otherwise)" }
        }
        return info
    }

    static func names(from checks: [Check]) -> String {
        checks.filter { $0.category == "name" }.compactMap { $0.accept.first }.joined(separator: ", ")
    }
    static func mean(_ values: [Int]) -> Int { values.isEmpty ? 0 : values.reduce(0, +) / values.count }
    static func percentile(_ values: [Int], _ p: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
    static func percent(_ rate: ErrorRate) -> String { String(format: "%.1f", rate.rate * 100) + "%" }

    public static func run(_ options: Options) async throws -> Receipt {
        try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
        var recognition: [RecognitionRow] = []
        var translation: [TranslationRow] = []
        var paced: [PacedRow] = []
        var load: [String: LoadGenerator.Summary] = [:]
        var resources: [String: PassResources] = [:]
        let log = RowLog(options.out.appendingPathComponent("rows.jsonl"))
        let sampler = ResourceSampler(monitors: options.monitors)
        for underLoad in options.load == nil ? [false] : [false, true] {
            let suffix = underLoad ? " (Qwen TTS running)" : ""
            let key = underLoad ? " under load" : ""
            if !options.recognizers.isEmpty {
                print("recognition pass\(suffix)")
                if underLoad { await options.load?.start() }
                await sampler.begin()
                recognition += await recognitionPass(options, underLoad: underLoad, log: log)
                resources["recognition" + key] = await sampler.end()
                if underLoad, let summary = await options.load?.stop() { load["recognition"] = summary }
            }
            if !options.pacedRecognizers.isEmpty {
                print("paced pass\(suffix)")
                if underLoad { await options.load?.start() }
                await sampler.begin()
                paced += await pacedPass(options, underLoad: underLoad, log: log)
                resources["paced" + key] = await sampler.end()
                if underLoad, let summary = await options.load?.stop() { load["paced"] = summary }
            }
            if !options.translators.isEmpty {
                print("translation pass\(suffix)")
                if underLoad { await options.load?.start() }
                await sampler.begin()
                translation += await translationPass(options, underLoad: underLoad, log: log)
                resources["translation" + key] = await sampler.end()
                if underLoad, let summary = await options.load?.stop() { load["translation"] = summary }
            }
        }

        var machine = "unknown"; var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0 { var buffer = [CChar](repeating: 0, count: size); if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 { machine = String(cString: buffer) } }
        var notes = ["Scoring tokens: lowercase, compatibility mapping, punctuation removed; number words folded to digits where the grammar allows (two numbers in a row stay separate), Chinese numerals folded, percent, currency and minus kept as tokens, and then every digit scored as one token, so '10:30', '1030' and 'ten thirty' agree. The error rate is therefore a token error rate (characters for Mandarin), and a wrong number costs one error per digit.",
                     "Checks pass when an accepted form appears inside the stretch of the transcript aligned with the check's reference sentence (edit-distance alignment, a few tokens of slack); checks without a sentence number search the whole transcript.",
                     "The '+context' recognizers and the translators' glossary receive the scripted names themselves, an oracle list: the best case for a participant list, not a prediction of one.",
                     "Recognition rows run the complete recording in phrase mode. Paced rows feed energy-gated phrases in real time (coverage = fraction of the recording fed) and measure delays from the nominal phrase end; phrase-mode engines also re-run the growing phrase every \(options.prefixEvery) s.",
                     "Translation rows translate the reference text, not recognizer output, so translation quality is isolated; meaning is rated by people from the review sheet.",
                     "Under-load rows were measured while Qwen TTS synthesized continuously in the engine; the load table reports that synthesis. The Qwen text translator shares the engine process and its one-request-at-a-time executor, so its under-load delay is queueing behind the synthesis unit in progress.",
                     "Resources per pass: CPU time (user plus system) and physical footprint per process from the kernel (proc_pid_rusage), MLX active, peak and cache bytes from each helper's stats reply, and the GPU's device utilization from the graphics driver's IOKit statistics polled every 250 ms. GPU utilization is for the whole GPU during the pass (every helper and any other app), so it is a load figure, not a per-model cost; nothing here needs privileges, and energy and thermal behaviour are not measured (they need powermetrics, which needs root)."]
        for (pass, summary) in load.sorted(by: { $0.key < $1.key }) where !summary.valid {
            notes.append("The under-load \(pass) pass is not valid: the load generator reported \(summary.errors) error(s)\(summary.stoppedEarly ? " and stopped early" : ""), so part of it ran without load.")
        }
        let receipt = Receipt(date: ISO8601DateFormatter().string(from: Date()), machine: machine, build: buildInfo(), settings: options.settings, models: options.models,
                              corpus: options.corpusLabel, items: options.items.map(\.id), recognition: recognition, translation: translation, paced: paced, load: load,
                              resources: resources, notes: notes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: options.out.appendingPathComponent("compare-receipt.json"))
        try summary(receipt).write(to: options.out.appendingPathComponent("compare-summary.md"), atomically: true, encoding: .utf8)
        try reviewSheet(receipt).write(to: options.out.appendingPathComponent("translation-review.md"), atomically: true, encoding: .utf8)
        return receipt
    }

    static func recognitionPass(_ options: Options, underLoad: Bool, log: RowLog) async -> [RecognitionRow] {
        var rows: [RecognitionRow] = []
        for recognizer in options.recognizers {
            for item in options.items where recognizer.languages.contains(item.language) {
                let seconds = (try? AudioDecoding.decode(item.audio, sampleRate: 16_000).count).map { Double($0) / 16_000 } ?? 0
                do {
                    let result = try await recognizer.recognize(item, context: names(from: item.checks))
                    let rate = Scoring.errorRate(reference: item.reference, hypothesis: result.text, language: item.language)
                    let outcomes = Scoring.runChecks(item.checks, reference: item.reference, hypothesis: result.text, language: item.language)
                    var byCategory: [String: String] = [:]
                    for category in Set(outcomes.map(\.category)) {
                        let subset = outcomes.filter { $0.category == category }
                        byCategory[category] = "\(subset.filter(\.passed).count)/\(subset.count)"
                    }
                    let resident = await recognizer.residentBytes()
                    rows.append(RecognitionRow(recognizer: recognizer.name, item: item.id, language: item.language, kind: item.kind, underLoad: underLoad, audioSeconds: round2(seconds),
                                               ms: result.ms, realTimeFactor: seconds > 0 ? (Double(result.ms) / 1000 / seconds * 1000).rounded() / 1000 : 0,
                                               errorRate: rate, checksPassed: outcomes.filter(\.passed).count, checksTotal: outcomes.count, byCategory: byCategory,
                                               hypothesis: result.text, detectedLanguage: result.detectedLanguage, residentBytesAfter: resident, error: nil))
                    print("  \(recognizer.name) · \(item.id): \(item.language == "zh" ? "CER" : "WER") \(percent(rate)) · checks \(outcomes.filter(\.passed).count)/\(outcomes.count) · \(result.ms) ms for \(String(format: "%.1f", seconds)) s")
                } catch {
                    rows.append(RecognitionRow(recognizer: recognizer.name, item: item.id, language: item.language, kind: item.kind, underLoad: underLoad, audioSeconds: round2(seconds), ms: -1, realTimeFactor: 0,
                                               errorRate: ErrorRate(errors: 0, total: 0), checksPassed: 0, checksTotal: item.checks.count, byCategory: [:], hypothesis: "", detectedLanguage: nil, residentBytesAfter: nil, error: "\(error)"))
                    print("  \(recognizer.name) · \(item.id): FAILED \(error)")
                }
                if let row = rows.last { log.write("recognition", row) }
            }
        }
        return rows
    }

    static func pacedPass(_ options: Options, underLoad: Bool, log: RowLog) async -> [PacedRow] {
        var rows: [PacedRow] = []
        for recognizer in options.pacedRecognizers {
            for item in options.items where recognizer.languages.contains(item.language) {
                do {
                    let samples = try AudioDecoding.decode(item.audio, sampleRate: 16_000)
                    let seconds = Double(samples.count) / 16_000
                    var results: [PhraseResult] = []
                    let phrases = PhraseSplitter.split(samples)
                    for (index, phrase) in phrases.enumerated() {
                        let outcome: PhraseOutcome
                        do {
                            outcome = try await recognizer.recognizePaced(Array(samples[phrase.start..<phrase.end]), language: item.language, context: names(from: item.checks), prefixEvery: options.prefixEvery)
                        } catch { throw EngineClientProblem("phrase \(index + 1): \(error)") }
                        results.append(PhraseResult(index: index + 1, startSeconds: round2(Double(phrase.start) / 16_000), seconds: round2(Double(phrase.end - phrase.start) / 16_000),
                                                    partialDelayMs: outcome.partialDelayMs, finalDelayMs: outcome.finalDelayMs, prefixRunMeanMs: outcome.prefixRunMeanMs, prefixRunMaxMs: outcome.prefixRunMaxMs, text: outcome.text))
                    }
                    let joined = results.map(\.text).joined(separator: " ")
                    let rate = Scoring.errorRate(reference: item.reference, hypothesis: joined, language: item.language)
                    let outcomes = Scoring.runChecks(item.checks, reference: item.reference, hypothesis: joined, language: item.language)
                    let finals = results.map(\.finalDelayMs)
                    let partials = results.compactMap(\.partialDelayMs)
                    let prefixRuns = results.compactMap(\.prefixRunMeanMs)
                    let resident = await recognizer.residentBytes()
                    rows.append(PacedRow(recognizer: recognizer.name, item: item.id, language: item.language, kind: item.kind, underLoad: underLoad, audioSeconds: round2(seconds), phrases: results,
                                         errorRate: rate, checksPassed: outcomes.filter(\.passed).count, checksTotal: outcomes.count,
                                         meanFinalDelayMs: mean(finals), p90FinalDelayMs: percentile(finals, 0.9), maxFinalDelayMs: finals.max() ?? 0,
                                         meanPartialDelayMs: partials.isEmpty ? nil : mean(partials), prefixRunMeanMs: prefixRuns.isEmpty ? nil : mean(prefixRuns),
                                         prefixRunMaxMs: results.compactMap(\.prefixRunMaxMs).max(), coverage: round2(PhraseSplitter.coverage(phrases, total: samples.count)),
                                         residentBytesAfter: resident, error: nil))
                    print("  paced \(recognizer.name) · \(item.id): \(results.count) phrases · \(item.language == "zh" ? "CER" : "WER") \(percent(rate)) · final delay mean \(mean(finals)) ms, p90 \(percentile(finals, 0.9)) ms"
                          + (partials.isEmpty ? "" : " · first partial \(mean(partials)) ms") + (prefixRuns.isEmpty ? "" : " · prefix re-run mean \(mean(prefixRuns)) ms"))
                } catch {
                    rows.append(PacedRow(recognizer: recognizer.name, item: item.id, language: item.language, kind: item.kind, underLoad: underLoad, audioSeconds: 0, phrases: [],
                                         errorRate: ErrorRate(errors: 0, total: 0), checksPassed: 0, checksTotal: item.checks.count, meanFinalDelayMs: 0, p90FinalDelayMs: 0, maxFinalDelayMs: 0,
                                         meanPartialDelayMs: nil, prefixRunMeanMs: nil, prefixRunMaxMs: nil, coverage: 0, residentBytesAfter: nil, error: "\(error)"))
                    print("  paced \(recognizer.name) · \(item.id): FAILED \(error)")
                }
                if let row = rows.last { log.write("paced", row) }
            }
        }
        return rows
    }

    static func translationPass(_ options: Options, underLoad: Bool, log: RowLog) async -> [TranslationRow] {
        var rows: [TranslationRow] = []
        for translator in options.translators {
            for pair in options.pairs {
                for item in options.items where item.language == pair.from && item.kind != "codec" {
                    let lines = item.referenceLines
                    var ok: [Int] = []
                    for (index, line) in lines.enumerated() {
                        let context = translator.supportsContext ? Array(lines[max(0, index - options.contextWindow)..<index]) : []
                        let glossary = item.checks.filter { $0.category == "name" }.compactMap { $0.accept.first }
                        do {
                            let result = try await translator.translate(line, from: pair.from, to: pair.to, context: context, glossary: glossary)
                            rows.append(TranslationRow(translator: translator.name, item: item.id, from: pair.from, to: pair.to, line: index + 1, underLoad: underLoad, source: line, output: result.text,
                                                       ms: result.ms, firstTokenMs: result.firstTokenMs, withContext: !context.isEmpty, error: nil))
                            ok.append(result.ms)
                        } catch {
                            rows.append(TranslationRow(translator: translator.name, item: item.id, from: pair.from, to: pair.to, line: index + 1, underLoad: underLoad, source: line, output: "",
                                                       ms: -1, firstTokenMs: nil, withContext: !context.isEmpty, error: "\(error)"))
                            if index == 0 { print("  \(translator.name) · \(item.id) → \(pair.to): line 1 FAILED \(error)") }
                        }
                        if let row = rows.last { log.write("translation", row) }
                    }
                    print("  \(translator.name) · \(item.id) → \(pair.to): \(ok.count)/\(lines.count) lines, mean \(mean(ok)) ms")
                }
            }
        }
        return rows
    }

    static func summary(_ receipt: Receipt) -> String {
        func load(_ flag: Bool) -> String { flag ? "TTS" : "–" }
        var md = "# Engine comparison · \(receipt.corpus)\n\n\(receipt.date) · \(receipt.machine)\n\n"
        md += "Build: " + receipt.build.keys.sorted().map { "\($0) \(receipt.build[$0]!)" }.joined(separator: " · ") + "\n\n"
        if !receipt.settings.isEmpty { md += "Settings: " + receipt.settings.keys.sorted().map { "\($0) = \(receipt.settings[$0]!)" }.joined(separator: "; ") + "\n\n" }
        if !receipt.models.isEmpty { md += "Models:\n" + receipt.models.keys.sorted().map { "- \($0): `\(receipt.models[$0]!)`" }.joined(separator: "\n") + "\n\n" }
        md += "## Recognition (whole recording, phrase mode)\n\n| Recognizer | Item | Load | Error rate | Checks | Names | Numbers | Dates | Negation | Corrections | Time / audio | RTF |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
        for row in receipt.recognition {
            if let error = row.error { md += "| \(row.recognizer) | \(row.item) | \(load(row.underLoad)) | failed: \(error) | | | | | | | | |\n"; continue }
            let cat = { (c: String) in row.byCategory[c] ?? "–" }
            md += "| \(row.recognizer) | \(row.item) | \(load(row.underLoad)) | \(percent(row.errorRate)) (\(row.errorRate.errors)/\(row.errorRate.total)) | \(row.checksPassed)/\(row.checksTotal) | \(cat("name")) | \(cat("number")) | \(cat("date")) | \(cat("negation")) | \(cat("correction")) | \(row.ms) ms / \(row.audioSeconds) s | \(row.realTimeFactor) |\n"
        }
        if !receipt.paced.isEmpty {
            md += "\n## Paced (phrases fed in real time)\n\n| Recognizer | Item | Load | Phrases | Coverage | Error rate | Checks | Final delay mean / p90 / max ms | First partial ms | Prefix re-run mean / max ms |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
            for row in receipt.paced {
                if let error = row.error { md += "| \(row.recognizer) | \(row.item) | \(load(row.underLoad)) | failed: \(error) | | | | | | |\n"; continue }
                md += "| \(row.recognizer) | \(row.item) | \(load(row.underLoad)) | \(row.phrases.count) | \(Int((row.coverage * 100).rounded()))% | \(percent(row.errorRate)) | \(row.checksPassed)/\(row.checksTotal) | \(row.meanFinalDelayMs) / \(row.p90FinalDelayMs) / \(row.maxFinalDelayMs) | \(row.meanPartialDelayMs.map(String.init) ?? "–") | \(row.prefixRunMeanMs.map { "\($0) / \(row.prefixRunMaxMs ?? 0)" } ?? "–") |\n"
            }
        }
        md += "\n## Translation (timing; meaning is rated from translation-review.md)\n\n| Translator | Item | Pair | Load | Lines ok | Mean ms | Mean first token ms |\n| --- | --- | --- | --- | --- | --- | --- |\n"
        let groups = Dictionary(grouping: receipt.translation) { "\($0.translator)|\($0.item)|\($0.from)→\($0.to)|\($0.underLoad ? 1 : 0)" }
        for key in groups.keys.sorted() {
            let rows = groups[key]!; let ok = rows.filter { $0.error == nil }
            let first = ok.compactMap(\.firstTokenMs)
            md += "| \(rows[0].translator) | \(rows[0].item) | \(rows[0].from)→\(rows[0].to) | \(load(rows[0].underLoad)) | \(ok.count)/\(rows.count) | \(mean(ok.map(\.ms))) | \(first.isEmpty ? "–" : String(mean(first))) |\n"
        }
        if !receipt.load.isEmpty {
            md += "\n## Qwen TTS during the under-load passes\n\n| Pass | Syntheses | Audio s | Generation RTF | Mean first audio ms | Errors | Valid |\n| --- | --- | --- | --- | --- | --- | --- |\n"
            for key in receipt.load.keys.sorted() {
                let s = receipt.load[key]!
                md += "| \(key) | \(s.syntheses) | \(s.audioSeconds) | \(s.realTimeFactor) | \(s.meanFirstAudioMs) | \(s.errors) | \(s.valid ? "yes" : "no") |\n"
            }
        }
        if !receipt.resources.isEmpty {
            md += "\n## Resources per pass\n\n" + ResourceSampler.tableHeader
            for key in receipt.resources.keys.sorted() { md += ResourceSampler.rows(key, receipt.resources[key]!) }
        }
        let footprint = Dictionary(grouping: receipt.recognition.filter { $0.error == nil }) { "\($0.recognizer)|\($0.underLoad ? 1 : 0)" }
        if !footprint.isEmpty {
            md += "\n## Footprint\n\n| Recognizer | Load | Audio s | ms per minute of speech | Resident MB after |\n| --- | --- | --- | --- | --- |\n"
            for key in footprint.keys.sorted() {
                let rows = footprint[key]!
                let audio = rows.map(\.audioSeconds).reduce(0, +), time = rows.map(\.ms).reduce(0, +)
                let resident = rows.compactMap(\.residentBytesAfter).last.map { String(format: "%.0f", Double($0) / 1_048_576) } ?? "–"
                md += "| \(rows[0].recognizer) | \(load(rows[0].underLoad)) | \(round2(audio)) | \(audio > 0 ? Int(Double(time) / audio * 60) : 0) | \(resident) |\n"
            }
        }
        md += "\nNotes:\n" + receipt.notes.map { "- \($0)" }.joined(separator: "\n") + "\n"
        return md
    }

    static func reviewSheet(_ receipt: Receipt) -> String {
        var md = "# Translation review sheet\n\nRate each output 0–3 (3 = meaning fully preserved; 0 = meaning changed). Mark names, numbers, dates, negations and corrections that went wrong.\n\n"
        let groups = Dictionary(grouping: receipt.translation.filter { !$0.underLoad }) { "\($0.item)|\($0.from)→\($0.to)|\($0.line)" }
        for key in groups.keys.sorted(by: { a, b in
            let pa = a.split(separator: "|"), pb = b.split(separator: "|")
            return pa[0] == pb[0] ? (pa[1] == pb[1] ? (Int(pa[2]) ?? 0) < (Int(pb[2]) ?? 0) : pa[1] < pb[1]) : pa[0] < pb[0]
        }) {
            let rows = groups[key]!
            md += "### \(rows[0].item) · line \(rows[0].line) · \(rows[0].from)→\(rows[0].to)\n\n**Source:** \(rows[0].source)\n\n| Translator | Output | Rating | Problems |\n| --- | --- | --- | --- |\n"
            for row in rows.sorted(by: { $0.translator < $1.translator }) { md += "| \(row.translator) | \(row.error ?? row.output) |  |  |\n" }
            md += "\n"
        }
        return md
    }
}
