import Foundation
import NookPluginSDK
import Translation
import TranslateCore

// Host-free checks. Uses the real SDK validators for the manifest and Core replay for journals.
// Never echoes payloads: output is counts and OK/FAIL only.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func argument(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

setvbuf(stdout, nil, _IOLBF, 0)   // progress lines reach a log file as they happen
let arguments = CommandLine.arguments.dropFirst()
do {
    if arguments.contains("--manifest") {
        let data: Data
        if let path = argument(after: "--manifest") , !path.hasPrefix("--") {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            data = try FileHandle.standardInput.readToEnd() ?? Data()
        }
        guard data.count <= 8192 else { throw ModuleProblem("Manifest exceeds its limit.") }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate()
        guard manifest.launchMode == "application" else { throw ModuleProblem("Translate must run in application launch mode.") }
        print("OK manifest \(manifest.id) \(manifest.version)")
    } else if arguments.contains("--translation-probe") {
        // Bisection aid: the standalone probe's exact sequence, run inside this binary.
        let availability = LanguageAvailability()
        let status = await availability.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "es"))
        print("harness process: status en->es = \(status)")
        let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "es"))
        do { try await session.prepareTranslation(); let r = try await session.translate("Thanks."); print("translate: \(r.targetText)") } catch { print("failed: \(error)") }
    } else if arguments.contains("--compare") {
        try await CompareCommand.run(arguments: Array(arguments))
    } else if arguments.contains("--listening-set") {
        try await CompareCommand.listeningSet(arguments: Array(arguments))
    } else if let backend = argument(after: "--prepare-model") {
        guard let helper = argument(after: backend == "tts" ? "--engine" : "--asr-helper"), let modelPrefix = argument(after: "--model") else {
            throw TranslateCheckProblem("--prepare-model <nemotron|qwen3asr|aligner> --asr-helper <TranslateASR> --model <checkpoint prefix>, or --prepare-model tts --engine <TranslateEngine> --model <prefix>")
        }
        try CompareCommand.prepareModel(helper: URL(fileURLWithPath: helper), backend: backend, model: try CompareCommand.model(modelPrefix))
    } else if let locale = argument(after: "--install-speech-locale") {
        try await CompareCommand.installSpeechLocale(locale)
    } else if let enginePath = argument(after: "--engine") {
        // TranslateCheck --engine <TranslateEngine> --model <dir> --voices <dir> --out <dir> [--stress N]
        // Voices dir holds <slot>-<lang>.wav + .txt for slots generic, local, remote (see Fixtures/Voices).
        guard let modelPath = argument(after: "--model"), let voicesPath = argument(after: "--voices"), let outPath = argument(after: "--out") else {
            throw TranslateProblem("Usage: --engine <binary> --model <dir> --voices <dir> --out <dir> [--stress N]")
        }
        let voicesDirectory = URL(fileURLWithPath: voicesPath)
        func voice(_ slot: String, _ file: String, language: String, text: String) throws -> EngineBench.Voice {
            let transcript = try String(contentsOf: voicesDirectory.appendingPathComponent(file + ".txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            return EngineBench.Voice(slot: slot, reference: voicesDirectory.appendingPathComponent(file + ".wav"), transcript: transcript, language: language, text: text)
        }
        let english = "I think we should confirm the delivery date first, and then look at the budget together before anyone commits to it."
        let spanish = "Creo que deberíamos confirmar primero la fecha de entrega, y después revisar el presupuesto juntos antes de que alguien se comprometa."
        let voices = [
            try voice("generic", "generic-en", language: "English", text: english),
            try voice("local", "local-en", language: "Spanish", text: spanish),
            try voice("remote", "remote-es", language: "English", text: english)
        ]
        let rounds = Int(argument(after: "--stress") ?? "") ?? 100
        try await EngineBench.execute(engine: URL(fileURLWithPath: enginePath), model: URL(fileURLWithPath: modelPath), voices: voices,
                                      out: URL(fileURLWithPath: outPath), stressRounds: rounds)
    } else if let path = argument(after: "--replay") {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= 256 * 1024 * 1024 else { throw TranslateProblem("Journal exceeds the check limit.") }
        let recovery = JournalReader.recover(data)
        let (transcript, summary) = Transcript.replay(recovery.events)
        print("OK replay events=\(recovery.events.count) utterances=\(transcript.count) lastSeq=\(summary.lastSeq) validBytes=\(recovery.validBytes) ignoredTail=\(recovery.ignoredTail) stoppedAtLine=\(recovery.stoppedAtLine.map(String.init) ?? "none") stoppedAtSeq=\(summary.stoppedAtSeq.map(String.init) ?? "none")")
    } else {
        print("Usage: TranslateCheck --manifest [path] | --replay <journal.jsonl> | --engine <bin> --model <dir> --voices <dir> --out <dir> | --compare (--corpus <dir> | --fixtures <dir>) --out <dir> [--asr-helper <bin>] [--engine <bin>] [--recognizers …] [--translators …] [--pairs en:es,es:en] | --install-speech-locale <id>")
        exit(2)
    }
} catch {
    fail("FAIL: \(error)")
}
