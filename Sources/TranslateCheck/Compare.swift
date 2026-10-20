import Foundation
import Speech
import TranslateCompare
import TranslateEngineClient

/// `TranslateCheck --compare`, `--listening-set`, `--prepare-model` and `--install-speech-locale`.
enum CompareCommand {
    static func modelsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NeroNookPlugins/cafe.nero.plugin.translate/Models")
    }

    /// Finds the imported checkpoint folder whose name starts with the given repository tail; two revisions
    /// of one model are an error, not a coin toss.
    static func model(_ prefix: String) throws -> URL {
        let root = modelsRoot()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix(prefix + "-") }.sorted()
        guard let name = names.first else { throw TranslateCheckProblem("Model not imported: \(prefix) (see docs/PROVENANCE.md)") }
        guard names.count == 1 else { throw TranslateCheckProblem("Several revisions of \(prefix) are imported (\(names.joined(separator: ", "))); keep one.") }
        return root.appendingPathComponent(name)
    }

    static let ttsVariants = ["base-1.7b-8bit": "Qwen3-TTS-12Hz-1.7B-Base-8bit", "base-1.7b-bf16": "Qwen3-TTS-12Hz-1.7B-Base-bf16", "base-0.6b-8bit": "Qwen3-TTS-12Hz-0.6B-Base-8bit"]
    /// The owner's choice (item 1, October 20, 2026): Mexican Spanish for Apple speech. Nemotron's checkpoint
    /// has prompts for es-ES and es-US only, so Latin American varieties use es-US there.
    static let defaultSpanishLocale = "es-MX"
    static func nemotronSpanish(for locale: String) -> String { locale == "es-ES" ? "es-ES" : "es-US" }
    static let loadSentence = "I think we should confirm the delivery date first, and then look at the budget together before anyone commits to it."

    static func value(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else { return nil }
        return arguments[index + 1]
    }
    static func list(_ text: String) -> [String] { text.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    /// One-time, unsandboxed load of a checkpoint so the runtime can write its derived files (the
    /// tokenizer.json it generates for Qwen3-ASR, the aligner and Base TTS checkpoints that ship without
    /// one) next to the checkpoint. Runtime loads are read-only. `tts` runs TranslateEngine, the others TranslateASR.
    static func prepareModel(helper: URL, backend: String, model: URL) throws {
        let process = Process()
        process.executableURL = helper
        process.arguments = backend == "tts" ? ["--model", model.path, "--prepare"] : ["--prepare", backend, model.path]
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin", "TMPDIR": FileManager.default.temporaryDirectory.path,
                               "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"]
        process.standardOutput = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TranslateCheckProblem("prepare \(backend) failed with status \(process.terminationStatus)") }
    }

    static func installSpeechLocale(_ identifier: String) async throws {
        let locale = Locale(identifier: identifier)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let before = await AssetInventory.status(forModules: [transcriber])
        print("\(identifier): status before = \(before)")
        if before == .installed { print("already installed"); return }
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { throw TranslateCheckProblem("Locale \(identifier) is not supported by SpeechTranscriber.") }
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("downloading Apple speech assets for \(identifier)…")
            try await request.downloadAndInstall()
        }
        let after = await AssetInventory.status(forModules: [transcriber])
        print("\(identifier): status after = \(after)")
        guard after == .installed else { throw TranslateCheckProblem("Assets for \(identifier) did not install.") }
    }

    // MARK: --compare

    static func run(arguments: [String]) async throws {
        func value(_ flag: String) -> String? { CompareCommand.value(flag, in: arguments) }
        let flags = Set(arguments.filter { $0.hasPrefix("--") })
        guard let outPath = value("--out") else { throw TranslateCheckProblem("--compare needs --out <dir>") }
        let out = URL(fileURLWithPath: outPath)
        let languages = Set(list(value("--languages") ?? "en,es"))
        var items: [CorpusItem]
        let label: String
        if let fixtures = value("--fixtures") {
            items = try CorpusLoader.loadFixtures(URL(fileURLWithPath: fixtures), languages: languages); label = "fixtures (synthetic voices; plumbing check only)"
        } else if let corpus = value("--corpus") {
            items = try CorpusLoader.load(corpus: URL(fileURLWithPath: corpus), languages: languages); label = corpus
        } else { throw TranslateCheckProblem("--compare needs --corpus <dir> or --fixtures <dir>") }
        if let kinds = value("--kinds") { let wanted = Set(list(kinds)); items = items.filter { wanted.contains($0.kind) } }
        guard !items.isEmpty else { throw TranslateCheckProblem("No corpus items for languages \(languages.sorted())") }
        let kinds = Dictionary(grouping: items, by: \.kind).map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
        print("corpus: \(items.count) items (\(label); \(kinds))")

        let recognizerNames = list(value("--recognizers") ?? "nemotron,qwen3asr-0.6b,qwen3asr-1.7b,apple")
        let translatorNames = list(value("--translators") ?? "apple,qwen3.5-2b,hymt2")
        let pairs: [(from: String, to: String)] = list(value("--pairs") ?? "en:es,es:en").compactMap {
            let parts = $0.split(separator: ":"); return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
        let paced = flags.contains("--paced")
        let prefixEvery = Double(value("--prefix-every") ?? "1") ?? 1
        let chunkMs = Int(value("--chunk-ms") ?? "560") ?? 560

        var recognizers: [any Recognizer] = []
        var pacedRecognizers: [any PacedRecognizer] = []
        var translators: [any Translator] = []
        var asrClients: [ASRClient] = []       // one helper per recognition candidate: a helper holds one model per backend, and memory is then per candidate
        var engine: EngineClient?
        var hymt2s: [HyMT2Translator] = []
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let spanishLocale = value("--spanish-locale") ?? defaultSpanishLocale
        let settings: [String: String] = ["chunkMs": "\(chunkMs)", "prefixEvery": "\(prefixEvery)", "contextWindow": "2", "spanishLocale": spanishLocale,
                                          "appleLocales": "en-US, \(spanishLocale), zh-CN", "nemotronLanguages": "en-US, \(nemotronSpanish(for: spanishLocale)), zh-CN",
                                          "applePaced": ApplePaced.options, "paced": "\(paced)", "load": "\(flags.contains("--load"))"]
        var models: [String: String] = [:]

        func launchEngine() async throws -> EngineClient {
            if let engine { return engine }
            guard let path = value("--engine") else { throw TranslateCheckProblem("--engine <TranslateEngine binary> is needed for qwen3.5-2b and --load") }
            let tts = try model("Qwen3-TTS-12Hz-1.7B-Base-8bit")
            let client = try await EngineClient.launch(engine: URL(fileURLWithPath: path), model: tts, log: out.appendingPathComponent("engine.log"))
            models["engine tts"] = tts.lastPathComponent
            engine = client
            return client
        }
        func shutdownAll() async {
            for client in asrClients { await client.shutdown() }
            await engine?.shutdown()
            for translator in hymt2s { await translator.shutdown() }
        }

        for name in recognizerNames where name != "none" {
            switch name {
            case "nemotron", "qwen3asr-0.6b", "qwen3asr-1.7b":
                guard let path = value("--asr-helper") else { throw TranslateCheckProblem("\(name) needs --asr-helper <TranslateASR binary>") }
                let asr = try await ASRClient.launch(helper: URL(fileURLWithPath: path), log: out.appendingPathComponent("asr-\(name).log"))
                asrClients.append(asr)
                let backend = name == "nemotron" ? "nemotron" : "qwen3asr"
                let folder = try model(name == "nemotron" ? "nemotron-3.5-asr-streaming-0.6b-8bit" : name == "qwen3asr-0.6b" ? "Qwen3-ASR-0.6B-4bit" : "Qwen3-ASR-1.7B-8bit")
                let loadMs = try await asr.load(backend: backend, model: folder)
                models[name] = folder.lastPathComponent
                print("loaded \(name) in \(loadMs) ms")
                // Nemotron takes the checkpoint's prompt keys (the helper refuses anything else): es-ES, or es-US for the Latin American varieties.
                let languageNames = backend == "nemotron" ? ["en": "en-US", "es": nemotronSpanish(for: spanishLocale), "zh": "zh-CN"] : ["en": "English", "es": "Spanish", "zh": "Chinese"]
                recognizers.append(HelperRecognizer(name: name, client: asr, backend: backend, languages: ["en", "es", "zh"], languageNames: languageNames, useContext: false))
                if backend == "qwen3asr" {
                    recognizers.append(HelperRecognizer(name: name + "+context", client: asr, backend: backend, languages: ["en", "es", "zh"], languageNames: languageNames, useContext: true))
                }
                if paced {
                    if backend == "nemotron" { pacedRecognizers.append(NemotronPaced(client: asr, chunkMs: chunkMs, languageNames: languageNames)) }
                    else { pacedRecognizers.append(PhraseModePaced(name: name, client: asr, backend: backend, languageNames: languageNames, useContext: false)) }
                }
            case "apple":
                let locales = ["en": "en-US", "es": spanishLocale, "zh": "zh-CN"]
                recognizers.append(AppleRecognizer(locales: locales))
                if paced { pacedRecognizers.append(ApplePaced(locales: locales)) }
            default: throw TranslateCheckProblem("Unknown recognizer \(name)")
            }
        }
        for name in translatorNames where name != "none" {
            let useContext = !name.hasSuffix("-nocontext")
            switch useContext ? name : String(name.dropLast("-nocontext".count)) {
            case "apple": translators.append(AppleTranslator())
            case "qwen3.5-2b":
                let client = try await launchEngine()
                if !translators.contains(where: { $0.name.hasPrefix("qwen3.5-2b") }) {
                    let text = try model("Qwen3.5-2B-4bit")
                    let loadMs = try await client.loadTranslator(model: text)
                    models["qwen3.5-2b"] = text.lastPathComponent
                    print("loaded qwen3.5-2b translator in \(loadMs) ms")
                }
                translators.append(EngineTranslator(name: useContext ? "qwen3.5-2b-4bit" : "qwen3.5-2b-4bit-nocontext", client: client, useContext: useContext))
            case "hymt2":
                guard let python = value("--hymt2-python"), let modelDir = value("--hymt2-model") else { throw TranslateCheckProblem("hymt2 needs --hymt2-python <venv python> --hymt2-model <dir>") }
                let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/hymt2-server.py")
                let translator = try await HyMT2Translator(python: URL(fileURLWithPath: python), script: script, model: URL(fileURLWithPath: modelDir), useContext: useContext, log: out.appendingPathComponent("hymt2.log"))
                models[translator.name] = modelDir
                print("loaded \(translator.name) in \(await translator.loadMs) ms")
                hymt2s.append(translator)
                translators.append(translator)
            default: throw TranslateCheckProblem("Unknown translator \(name)")
            }
        }
        var monitors = [ResourceMonitor(name: "TranslateCheck (Apple in-process)", pid: getpid())]
        for (index, client) in asrClients.enumerated() {
            let name = recognizerNames.filter { $0 != "none" && $0 != "apple" }[index]
            monitors.append(ResourceMonitor(name: "asr-\(name)", pid: client.processIdentifier, stats: { try await client.stats() }))
        }
        for translator in hymt2s { monitors.append(ResourceMonitor(name: translator.name, pid: translator.processIdentifier)) }
        var load: LoadGenerator?
        if flags.contains("--load") {
            let client = try await launchEngine()
            let voice = URL(fileURLWithPath: value("--load-voice") ?? "Fixtures/Voices/generic-en")
            let transcript = try String(contentsOf: voice.appendingPathExtension("txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let prepared = try await client.prepareVoice(slot: "generic", reference: voice.appendingPathExtension("wav"), transcript: transcript, language: "English")
            print("load voice ready in \(prepared.prepareMs) ms; Qwen TTS synthesizes continuously during the under-load passes")
            load = LoadGenerator(engine: client, slot: "generic", text: loadSentence)
        }
        if let engine { monitors.append(ResourceMonitor(name: "engine (TTS\(models["qwen3.5-2b"] == nil ? "" : " + Qwen text"))", pid: engine.processIdentifier, stats: { try await engine.stats() })) }

        // Warm every candidate once so the first row of a receipt does not carry a model's warm-up
        // (first translation after a load, first recognition of a session) — plan §6.1 measures warm.
        // A warm-up failure is printed: the same failure will show up as an error row.
        do {
            for recognizer in recognizers {
                guard let item = items.first(where: { recognizer.languages.contains($0.language) }) else { continue }
                do { _ = try await recognizer.recognize(item, context: nil) } catch { print("warm-up: \(recognizer.name) on \(item.id) failed: \(error)") }
            }
            for recognizer in pacedRecognizers {
                guard let item = items.first(where: { recognizer.languages.contains($0.language) }) else { continue }
                do {
                    let samples = try AudioDecoding.decode(item.audio, sampleRate: 16_000)
                    _ = try await recognizer.recognizePaced(Array(samples.prefix(48_000)), language: item.language, context: nil, prefixEvery: 0)
                } catch { print("warm-up: paced \(recognizer.name) on \(item.id) failed: \(error)") }
            }
            for translator in translators {
                for pair in pairs {
                    do { _ = try await translator.translate("Thank you, see you on Monday.", from: pair.from, to: pair.to, context: [], glossary: []) }
                    catch { print("warm-up: \(translator.name) \(pair.from)→\(pair.to) failed: \(error)") }
                }
            }
            print("candidates warm")
            let receipt = try await CompareRunner.run(CompareRunner.Options(items: items, recognizers: recognizers, pacedRecognizers: pacedRecognizers, translators: translators, pairs: pairs,
                                                                            load: load, prefixEvery: prefixEvery, settings: settings, models: models, monitors: monitors, out: out, corpusLabel: label))
            print("wrote \(out.appendingPathComponent("compare-receipt.json").path): \(receipt.recognition.count) recognition rows, \(receipt.paced.count) paced rows, \(receipt.translation.count) translation rows")
        } catch {
            await shutdownAll()
            throw error
        }
        await shutdownAll()
    }

    // MARK: --draft-gold

    /// Drafts a transcript for every recording under raw/<lang>/ that has no gold text yet (the natural
    /// parts), as gold/<lang>/<name>.draft.txt, one sentence per line. The speaker corrects it and renames
    /// it to <name>.txt; until then the loader skips the recording. Reference takes and scripted readings
    /// are left alone. Qwen3-ASR 1.7B by default (`--recognizer nemotron` or `qwen3asr-0.6b` otherwise).
    static func draftGold(arguments: [String]) async throws {
        func value(_ flag: String) -> String? { CompareCommand.value(flag, in: arguments) }
        guard let corpusPath = value("--corpus"), let helper = value("--asr-helper") else { throw TranslateCheckProblem("--draft-gold needs --corpus <dir> --asr-helper <TranslateASR> [--recognizer qwen3asr-1.7b] [--languages en,es,zh]") }
        let corpus = URL(fileURLWithPath: corpusPath)
        let languages = list(value("--languages") ?? "en,es,zh")
        let name = value("--recognizer") ?? "qwen3asr-1.7b"
        let backend = name == "nemotron" ? "nemotron" : "qwen3asr"
        let prefix = name == "nemotron" ? "nemotron-3.5-asr-streaming-0.6b-8bit" : name == "qwen3asr-0.6b" ? "Qwen3-ASR-0.6B-4bit" : "Qwen3-ASR-1.7B-8bit"
        let spanish = value("--spanish-locale") ?? defaultSpanishLocale
        let languageNames = backend == "nemotron" ? ["en": "en-US", "es": nemotronSpanish(for: spanish), "zh": "zh-CN"] : ["en": "English", "es": "Spanish", "zh": "Chinese"]
        var pending: [(language: String, file: URL)] = []
        for language in languages {
            let raw = corpus.appendingPathComponent("raw/\(language)")
            for file in ((try? FileManager.default.contentsOfDirectory(atPath: raw.path)) ?? []).sorted() {
                let url = raw.appendingPathComponent(file)
                let base = url.deletingPathExtension().lastPathComponent
                guard CorpusLoader.audioExtensions.contains(url.pathExtension.lowercased()), !base.hasPrefix("reference") else { continue }
                let gold = corpus.appendingPathComponent("gold/\(language)/\(base).txt")
                let draft = corpus.appendingPathComponent("gold/\(language)/\(base).draft.txt")
                if FileManager.default.fileExists(atPath: gold.path) { continue }
                if FileManager.default.fileExists(atPath: draft.path) { print("\(language)/\(base): draft exists, waiting for correction (rename to \(base).txt)"); continue }
                pending.append((language, url))
            }
        }
        guard !pending.isEmpty else { print("nothing to draft: every recording has gold text or a draft"); return }
        let asr = try await ASRClient.launch(helper: URL(fileURLWithPath: helper), log: nil)
        defer { Task { await asr.shutdown() } }
        _ = try await asr.load(backend: backend, model: try model(prefix))
        for (language, url) in pending {
            let samples = try AudioDecoding.decode(url, sampleRate: Double(asr.sampleRate))
            let seconds = Double(samples.count) / Double(asr.sampleRate)
            guard seconds <= 600 else { print("\(language)/\(url.lastPathComponent): \(Int(seconds)) s is longer than the ten-minute limit; split the recording"); continue }
            let result = try await asr.transcribe(backend: backend, samples: samples, language: languageNames[language])
            let lines = GoldDraft.sentences(result.text)
            let base = url.deletingPathExtension().lastPathComponent
            let draft = corpus.appendingPathComponent("gold/\(language)/\(base).draft.txt")
            try FileManager.default.createDirectory(at: draft.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: draft, atomically: true, encoding: .utf8)
            print("\(language)/\(base): \(lines.count) sentences drafted by \(name) from \(String(format: "%.0f", seconds)) s → \(draft.path); correct it and rename to \(base).txt")
        }
    }

    // MARK: --voices-from-corpus

    /// Turns each speaker's reference take (raw/<lang>/reference.<ext>, sentences 1–3 of the script read as
    /// one take) into a listening-set voice: <slot>-<lang>.wav at 24 kHz plus the exact transcript, from
    /// gold/<lang>/reference.txt when present, else the first three scripted lines. Default slots:
    /// en→local, es→remote, zh→generic (`--slots en:local,es:remote`).
    static func voicesFromCorpus(arguments: [String]) throws {
        func value(_ flag: String) -> String? { CompareCommand.value(flag, in: arguments) }
        guard let corpusPath = value("--corpus"), let outPath = value("--out") else { throw TranslateCheckProblem("--voices-from-corpus needs --corpus <dir> --out <voices dir> [--languages en,es] [--slots en:local,es:remote]") }
        let corpus = URL(fileURLWithPath: corpusPath), out = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var slots = ["en": "local", "es": "remote", "zh": "generic"]
        for pair in list(value("--slots") ?? "") { let parts = pair.split(separator: ":"); if parts.count == 2 { slots[String(parts[0])] = String(parts[1]) } }
        var made = 0
        for language in list(value("--languages") ?? "en,es,zh") {
            guard let slot = slots[language] else { continue }
            let raw = corpus.appendingPathComponent("raw/\(language)")
            guard let file = ((try? FileManager.default.contentsOfDirectory(atPath: raw.path)) ?? []).sorted().first(where: {
                let url = raw.appendingPathComponent($0); return url.deletingPathExtension().lastPathComponent == "reference" && CorpusLoader.audioExtensions.contains(url.pathExtension.lowercased()) }) else {
                print("\(language): no raw/\(language)/reference.<wav|m4a|…>; the listening set gets no \(slot) voice"); continue
            }
            let samples = try AudioDecoding.decode(raw.appendingPathComponent(file), sampleRate: 24_000)
            let seconds = Double(samples.count) / 24_000
            guard seconds >= 3, seconds <= 30 else { print("\(language)/\(file): \(String(format: "%.1f", seconds)) s; a reference must be 3–30 s"); continue }
            let transcript: String
            if let own = try? String(contentsOf: corpus.appendingPathComponent("gold/\(language)/reference.txt"), encoding: .utf8) { transcript = own }
            else if let scripted = try? String(contentsOf: corpus.appendingPathComponent("gold/\(language)/scripted.txt"), encoding: .utf8) {
                transcript = scripted.split(whereSeparator: \.isNewline).prefix(3).joined(separator: " ")
            } else { throw TranslateCheckProblem("\(language): no gold/\(language)/reference.txt or scripted.txt for the reference transcript") }
            try AudioDecoding.writeWAV(samples, sampleRate: 24_000, to: out.appendingPathComponent("\(slot)-\(language).wav"))
            try (transcript.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: out.appendingPathComponent("\(slot)-\(language).txt"), atomically: true, encoding: .utf8)
            print("\(slot)-\(language): \(String(format: "%.1f", seconds)) s from raw/\(language)/\(file)")
            made += 1
        }
        print("\(made) voice(s) under \(out.path); the folder is git-ignored")
    }

    // MARK: --listening-set

    static func listeningSet(arguments: [String]) async throws {
        func value(_ flag: String) -> String? { CompareCommand.value(flag, in: arguments) }
        guard let enginePath = value("--engine"), let outPath = value("--out") else { throw TranslateCheckProblem("--listening-set needs --engine <TranslateEngine> --out <dir> [--voices <dir>] [--variants a,b] [--intervals 0.32,0.16] [--sentences <json>] [--languages en,es,zh] [--asr-helper <TranslateASR>]") }
        let out = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let voicesDirectory = URL(fileURLWithPath: value("--voices") ?? "Fixtures/Voices")
        var voices: [ListeningSet.Voice] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: voicesDirectory.path).sorted() where name.hasSuffix(".wav") {
            let base = String(name.dropLast(4))
            guard let dash = base.lastIndex(of: "-") else { continue }
            let slot = String(base[..<dash]), language = String(base[base.index(after: dash)...])
            guard ["generic", "local", "remote"].contains(slot) else { continue }
            let transcript = try String(contentsOf: voicesDirectory.appendingPathComponent(base + ".txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            voices.append(ListeningSet.Voice(slot: slot, name: base, reference: voicesDirectory.appendingPathComponent(name), transcript: transcript, language: language))
        }
        guard !voices.isEmpty else { throw TranslateCheckProblem("No <slot>-<lang>.wav voices in \(voicesDirectory.path)") }
        let variants = try list(value("--variants") ?? "base-1.7b-8bit,base-1.7b-bf16,base-0.6b-8bit").map { name -> ListeningSet.Variant in
            guard let prefix = ttsVariants[name] else { throw TranslateCheckProblem("Unknown TTS variant \(name); known: \(ttsVariants.keys.sorted().joined(separator: ", "))") }
            return ListeningSet.Variant(name: name, model: try model(prefix))
        }
        let intervals = list(value("--intervals") ?? "0.32,0.16").compactMap(Double.init)
        var sentences = ListeningSet.defaultSentences
        if let path = value("--sentences") { sentences = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
        if let languages = value("--languages") { let wanted = Set(list(languages)); sentences = sentences.filter { wanted.contains($0.key) } }
        let log = out.appendingPathComponent("helpers-stderr.log")
        var load: (client: ASRClient, samples: [Float])?
        if let helper = value("--asr-helper") {
            let client = try await ASRClient.launch(helper: URL(fileURLWithPath: helper), log: log)
            _ = try await client.load(backend: "nemotron", model: try model("nemotron-3.5-asr-streaming-0.6b-8bit"))
            let clip = URL(fileURLWithPath: value("--load-clip") ?? "Fixtures/Voices/generic-en.wav")
            load = (client, try AudioDecoding.decode(clip, sampleRate: 16_000))
            print("Nemotron ready; one pass per variant runs while recognition streams")
        }
        let receipt: ListeningSet.Receipt
        do {
            receipt = try await ListeningSet.run(ListeningSet.Options(engine: URL(fileURLWithPath: enginePath), variants: variants, voices: voices, sentences: sentences, intervals: intervals,
                                                                      recognitionLoad: load, out: out, log: log))
        } catch { await load?.client.shutdown(); throw error }
        await load?.client.shutdown()
        print("wrote \(receipt.clips.count) clips, listening-sheet.md and tts-summary.md under \(out.path); private/key.json and private/listening-receipt.json stay with the organizer")
    }
}

struct TranslateCheckProblem: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
