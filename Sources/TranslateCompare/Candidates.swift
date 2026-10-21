import AVFoundation
import Darwin
import Foundation
import Speech
import Translation
import TranslateEngineClient

public struct RecognizedText: Sendable {
    public let text: String
    public let ms: Int
    public let detectedLanguage: String?
}

public protocol Recognizer: Sendable {
    var name: String { get }
    var languages: Set<String> { get }
    /// Recognizes a complete recording. `context` is a names/terms list for engines that take one.
    func recognize(_ item: CorpusItem, context: String?) async throws -> RecognizedText
    /// Resident memory of the process that holds the model, when it is a helper of its own.
    func residentBytes() async -> UInt64?
}
public extension Recognizer { func residentBytes() async -> UInt64? { nil } }

public struct Translated: Sendable {
    public let text: String
    public let ms: Int
    public let firstTokenMs: Int?
}

public protocol Translator: Sendable {
    var name: String { get }
    var supportsContext: Bool { get }
    func translate(_ text: String, from: String, to: String, context: [String], glossary: [String]) async throws -> Translated
}

// MARK: Recognizers

/// A backend inside TranslateASR (Nemotron or Qwen3-ASR), phrase mode.
public struct HelperRecognizer: Recognizer {
    public let name: String
    public let languages: Set<String>
    let client: ASRClient
    let backend: String
    let languageNames: [String: String]
    let useContext: Bool

    public init(name: String, client: ASRClient, backend: String, languages: Set<String>, languageNames: [String: String], useContext: Bool) {
        self.name = name; self.client = client; self.backend = backend; self.languages = languages; self.languageNames = languageNames; self.useContext = useContext
    }

    public func recognize(_ item: CorpusItem, context: String?) async throws -> RecognizedText {
        let samples = try AudioDecoding.decode(item.audio, sampleRate: Double(client.sampleRate))
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await client.transcribe(backend: backend, samples: samples, language: languageNames[item.language], context: useContext ? context : nil)
        return RecognizedText(text: result.text, ms: Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()), detectedLanguage: result.language)
    }
    public func residentBytes() async -> UInt64? { (try? await client.stats())?.residentBytes }
}

/// Apple SpeechAnalyzer with SpeechTranscriber, file input, final results only. With `useContext`, the
/// names list goes in as the analyzer's contextual strings, Apple's counterpart of Qwen's `context`.
public struct AppleRecognizer: Recognizer {
    public let name: String
    public let languages: Set<String>
    let locales: [String: String]
    let useContext: Bool
    public init(locales: [String: String], useContext: Bool = false) {
        self.locales = locales; self.languages = Set(locales.keys); self.useContext = useContext
        self.name = useContext ? "apple-speech+context" : "apple-speech"
    }

    static func analysisContext(_ names: String?) -> AnalysisContext? {
        guard let names, !names.isEmpty else { return nil }
        let context = AnalysisContext()
        context.contextualStrings[.general] = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return context
    }

    public func recognize(_ item: CorpusItem, context: String?) async throws -> RecognizedText {
        guard let localeID = locales[item.language] else { throw EngineClientProblem("No Apple locale for \(item.language).") }
        let transcriber = SpeechTranscriber(locale: Locale(identifier: localeID), preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if useContext, let analysis = Self.analysisContext(context) { try await analyzer.setContext(analysis) }
        let file = try AVAudioFile(forReading: item.audio)
        let started = ProcessInfo.processInfo.systemUptime
        let collector = Task { () throws -> [String] in
            var finals: [String] = []
            for try await result in transcriber.results where result.isFinal { finals.append(String(result.text.characters)) }
            return finals
        }
        do { try await analyzer.start(inputAudioFile: file, finishAfterFile: true) } catch {
            collector.cancel()
            throw EngineClientProblem("Apple speech failed for \(localeID) (asset status \(status)): \(error)")
        }
        let finals = try await collector.value
        return RecognizedText(text: finals.joined(separator: " "), ms: Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()), detectedLanguage: nil)
    }
}

// MARK: Translators

/// Apple Translation with installed language packs: one prepared session per language pair, kept on the
/// main actor. The binary must be stamped with SDK 27.0 or later (see BuildStamp).
@MainActor public final class AppleTranslator: Translator {
    public nonisolated let name = "apple-translation"
    public nonisolated let supportsContext = false
    private var sessions: [String: TranslationSession] = [:]
    public nonisolated init() {}
    private func session(from: String, to: String) async throws -> TranslationSession {
        if let existing = sessions[from + ">" + to] { return existing }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
        guard status == .installed else {
            let stamp = BuildStamp.programSDKVersion() ?? "unknown"
            let hint = BuildStamp.programSDK(atLeast: 27) ? "" : " This binary is stamped with SDK \(stamp); Translation reports installed packs as `supported` below 27.0 (README.md, building)."
            throw EngineClientProblem("Apple Translation \(from)→\(to) is \(status), not installed.\(hint)")
        }
        let session = TranslationSession(installedSource: Locale.Language(identifier: from), target: Locale.Language(identifier: to))
        try await session.prepareTranslation()
        sessions[from + ">" + to] = session
        return session
    }
    public func translate(_ text: String, from: String, to: String, context: [String], glossary: [String]) async throws -> Translated {
        let session = try await session(from: from, to: to)
        let started = ProcessInfo.processInfo.systemUptime
        let response = try await session.translate(text)
        return Translated(text: response.targetText, ms: Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()), firstTokenMs: nil)
    }
}

/// The Qwen text model inside TranslateEngine.
public struct EngineTranslator: Translator {
    public let name: String
    public let supportsContext: Bool
    let client: EngineClient
    public init(name: String, client: EngineClient, useContext: Bool = true) { self.name = name; self.client = client; self.supportsContext = useContext }
    public func translate(_ text: String, from: String, to: String, context: [String], glossary: [String]) async throws -> Translated {
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await client.translate(text, from: from, to: to, context: context, glossary: glossary)
        return Translated(text: result.text, ms: Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()), firstTokenMs: result.firstTokenMs)
    }
}

/// Hy-MT2 through scripts/hymt2-server.py in Voice's interpreter environment (measurement only). The
/// server runs under the helpers' sandbox profile with `-I -B` (no site, no bytecode written into
/// Voice's environment); replies are matched by id, non-JSON lines are skipped, and every reply has a deadline.
public actor HyMT2Translator: Translator {
    public nonisolated let name: String
    public nonisolated let supportsContext: Bool
    private let process = Process()
    private let input: FileHandle
    private let reader: LineReader
    private var broken: String?
    public private(set) var loadMs = -1
    nonisolated(unsafe) public private(set) var processIdentifier: Int32 = 0

    public init(python: URL, script: URL, model: URL, useContext: Bool = true, log: URL? = nil) async throws {
        name = useContext ? "hy-mt2-1.8b-4bit" : "hy-mt2-1.8b-4bit-nocontext"
        supportsContext = useContext
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", HelperClient.sandboxProfile, python.path, "-I", "-B", script.path, "--model", model.path]
        process.standardInput = stdin; process.standardOutput = stdout
        if let log {
            let descriptor = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            process.standardError = descriptor >= 0 ? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) : FileHandle.nullDevice
        } else { process.standardError = FileHandle.nullDevice }
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin", "TMPDIR": FileManager.default.temporaryDirectory.path,
                               "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        input = stdin.fileHandleForWriting
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        reader = LineReader(stdout.fileHandleForReading)
        try process.run()
        processIdentifier = process.processIdentifier
        let ready = try await Self.reply(from: reader, id: nil, timeout: 300)
        if let error = ready["error"] as? String { throw EngineClientProblem("Hy-MT2: \(error)") }
        loadMs = (ready["loadMs"] as? Int) ?? -1
    }

    /// Blocking line reader used from a detached task, so the actor itself never blocks a thread.
    final class LineReader: @unchecked Sendable {
        private let handle: FileHandle
        private var buffer = Data()
        private let lock = NSLock()
        init(_ handle: FileHandle) { self.handle = handle }
        /// The next JSON object line whose `id` matches (or any object when `id` is nil); other lines are skipped.
        func next(matching id: String?) throws -> [String: Any] {
            lock.lock(); defer { lock.unlock() }
            while true {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                    if let id, (object["id"] as? String) != id { continue }
                    return object
                }
                let chunk = handle.availableData
                guard !chunk.isEmpty else { throw EngineClientProblem("Hy-MT2 server closed its output.") }
                buffer.append(chunk)
                guard buffer.count < 1_048_576 else { throw EngineClientProblem("Hy-MT2 reply too large.") }
            }
        }
    }

    static func reply(from reader: LineReader, id: String?, timeout: TimeInterval) async throws -> [String: Any] {
        try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask { try await Task.detached { try reader.next(matching: id) }.value }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); throw EngineClientProblem("Hy-MT2 gave no reply within \(Int(timeout)) s.") }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    public func translate(_ text: String, from: String, to: String, context: [String], glossary: [String]) async throws -> Translated {
        if let broken { throw EngineClientProblem("Hy-MT2 is unusable after an earlier failure: \(broken)") }
        let id = UUID().uuidString
        let request: [String: Any] = ["id": id, "text": text, "target": to, "context": context]
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try input.write(contentsOf: try JSONSerialization.data(withJSONObject: request) + Data([10]))
            let reply = try await Self.reply(from: reader, id: id, timeout: 120)
            if let error = reply["error"] as? String { throw EngineClientProblem("Hy-MT2: \(error)") }
            return Translated(text: reply["text"] as? String ?? "", ms: Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()), firstTokenMs: reply["firstTokenMs"] as? Int)
        } catch {
            // After a timeout the detached read may still own the pipe; later rows must not wait behind it.
            if "\(error)".contains("no reply within") || "\(error)".contains("closed its output") { broken = "\(error)" }
            throw error
        }
    }

    public func shutdown() { try? input.close(); process.terminate() }
}
