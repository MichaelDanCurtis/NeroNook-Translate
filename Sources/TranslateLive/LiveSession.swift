import AVFoundation
import Foundation
import TranslateAudio
import TranslateCore
import TranslateEngineClient

/// A caption line in the session window: the original as recognized, its translation, and what happened to it.
public struct LiveCaption: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var original: String
    public var translated: String?
    public var error: String?
    public var at: Date
}

/// The reference clip a voice slot is prepared from: 3–30 s of the speaker with its exact words.
public struct VoiceReference: Codable, Equatable, Sendable {
    public var url: URL
    public var transcript: String
    public init(url: URL, transcript: String) { self.url = url; self.transcript = transcript }
}

public struct LiveConfiguration: Codable, Equatable, Sendable {
    public var sourceLanguage = "en"     // what I speak
    public var targetLanguage = "es"     // what the other person hears
    public var microphoneUID: String?
    public var reference: VoiceReference?
    public var hear = true               // play the translation through the speakers (the self-test)
    public var names: [String] = []      // participant names for recognition and the glossary
    public init() {}
}

public enum LiveState: Equatable, Sendable {
    case idle
    case preparing(String)
    case listening
    case stopping
    case failed(String)
}

/// The self-test lane: microphone → Apple recognition → Apple translation → Qwen TTS in the prepared voice
/// → speakers. Everything runs in the app except synthesis, which is the sandboxed engine helper.
@MainActor public final class LiveSession: ObservableObject {
    @Published public private(set) var state: LiveState = .idle
    @Published public private(set) var captions: [LiveCaption] = []
    @Published public private(set) var partial = ""
    @Published public private(set) var inputLevel: Float = 0
    @Published public private(set) var outputLevel: Float = 0
    @Published public private(set) var engineStatus = "Engine not started"
    @Published public private(set) var synthesis = SynthesisQueue.Progress(queued: 0, speaking: false)
    @Published public var configuration = LiveConfiguration() { didSet { saveConfiguration() } }

    public let storage: URL
    private let capture = MicrophoneCapture()
    private let playback = SpeechPlayback()
    private let translation = AppleTranslation()
    private var engine: EngineClient?
    private var queue: SynthesisQueue?
    private var recognition: AppleRecognitionStream?
    private var feeding: Task<Void, Never>?
    private var listening: Task<Void, Never>?
    private var fileDone: CheckedContinuation<Void, Never>?
    private var translationsInFlight = 0
    private var translationWaiters: [CheckedContinuation<Void, Never>] = []
    private var configurationURL: URL { storage.appendingPathComponent("live-configuration.json") }

    /// Where the audio comes from: the microphone (the product) or a recording fed at real-time pace (the
    /// headless self-test, which exercises the same pipeline without a microphone).
    public enum Source: Sendable { case microphone, file(URL) }

    public init(storage: URL) {
        self.storage = storage
        if let data = try? Data(contentsOf: configurationURL), let saved = try? JSONDecoder().decode(LiveConfiguration.self, from: data) { configuration = saved }
        capture.onLevel = { [weak self] level in self?.inputLevel = level }
        playback.onLevel = { [weak self] level in self?.outputLevel = level }
        capture.onFailure = { [weak self] message in self?.fail("Microphone capture stopped: \(message)") }
    }

    private func saveConfiguration() {
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(configuration) { try? data.write(to: configurationURL) }
    }

    public var canStart: Bool { if case .listening = state { return false }; if case .preparing = state { return false }; if case .stopping = state { return false }; return true }

    public func start() async { await start(source: .microphone) }

    public func start(source: Source) async {
        guard canStart else { return }
        captions.removeAll(); partial = ""
        let from = configuration.sourceLanguage, to = configuration.targetLanguage
        do {
            state = .preparing("Checking language assets")
            let locale = Locale(identifier: Languages.speechLocale(from))
            if !(await AppleRecognitionStream.assetsInstalled(locale: locale)) {
                state = .preparing("Installing speech assets for \(Languages.name(from))")
                try await AppleRecognitionStream.installAssets(locale: locale)
            }
            try await translation.prepare(from: from, to: to)

            state = .preparing("Starting the speech engine")
            try FileManager.default.createDirectory(at: storage.appendingPathComponent("Logs"), withIntermediateDirectories: true)
            let engine = try await EngineClient.launch(engine: try HelperLocator.engine(), model: try ModelLocator.qwenBase(in: storage), log: storage.appendingPathComponent("Logs/engine.log"))
            self.engine = engine
            engineStatus = "Engine ready in \(engine.startupMs) ms"
            if let reference = configuration.reference {
                state = .preparing("Preparing your voice")
                guard let qwenLanguage = Languages.qwenName(to) else { throw LiveProblem("No voice language for \(to).") }
                let prepared = try await engine.prepareVoice(slot: "local", reference: reference.url, transcript: reference.transcript, language: qwenLanguage)
                engineStatus = "Voice prepared in \(prepared.prepareMs) ms from \(String(format: "%.1f", prepared.seconds)) s"
            } else if configuration.hear {
                engineStatus = "No reference clip: captions only"
            }
            try playback.start()
            let queue = SynthesisQueue(engine: engine, playback: playback)
            await queue.setProgressHandler { [weak self] progress in Task { @MainActor in self?.synthesis = progress } }
            self.queue = queue

            state = .preparing("Starting recognition")
            let recognition = try await AppleRecognitionStream(locale: locale, names: configuration.names)
            self.recognition = recognition
            try await recognition.start()
            switch source {
            case .microphone:
                let chunks = try capture.start(deviceUID: configuration.microphoneUID)
                feeding = Task { for await chunk in chunks { recognition.feed(chunk) } }
            case .file(let url):
                let samples = try AudioDecoding.decode(url, sampleRate: 16_000)
                feeding = Task { [weak self] in
                    // 100 ms chunks at wall-clock pace, like the microphone; then let the analyzer finalize.
                    let chunk = 1_600
                    let started = ProcessInfo.processInfo.systemUptime
                    var offset = 0
                    while offset < samples.count, !Task.isCancelled {
                        let end = min(samples.count, offset + chunk)
                        let due = started + Double(end) / 16_000
                        let now = ProcessInfo.processInfo.systemUptime
                        if due > now { try? await Task.sleep(nanoseconds: UInt64((due - now) * 1_000_000_000)) }
                        recognition.feed(Array(samples[offset..<end]))
                        offset = end
                    }
                    guard !Task.isCancelled else { return }
                    await recognition.finish()
                    await self?.fileEnded()
                }
            }
            listening = Task { [weak self] in
                for await event in recognition.results { await self?.handle(event) }
            }
            state = .listening
        } catch {
            await teardown()
            state = .failed("\(error)")
        }
    }

    private func handle(_ event: RecognitionEvent) async {
        switch event {
        case .partial(let text):
            partial = text
        case .final(let text):
            partial = ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let caption = LiveCaption(id: UUID(), original: trimmed, translated: nil, error: nil, at: Date())
            captions.append(caption)
            if captions.count > 200 { captions.removeFirst(captions.count - 200) }
            translationsInFlight += 1
            defer { translationsInFlight -= 1; if translationsInFlight == 0 { for waiter in translationWaiters { waiter.resume() }; translationWaiters.removeAll() } }
            do {
                let translated = try await translation.translate(trimmed, from: configuration.sourceLanguage, to: configuration.targetLanguage)
                update(caption.id) { $0.translated = translated }
                if configuration.hear, configuration.reference != nil, let queue { await queue.speak(translated, slot: "local") }
            } catch {
                update(caption.id) { $0.error = "\(error)" }
            }
        case .failed(let message):
            fail("Recognition failed: \(message)")
        }
    }

    private func update(_ id: UUID, _ change: (inout LiveCaption) -> Void) {
        guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
        change(&captions[index])
    }

    private func fail(_ message: String) {
        guard case .listening = state else { return }
        state = .failed(message)
        Task { await teardown() }
    }

    public func stop() async {
        guard case .listening = state else { return }
        state = .stopping
        await teardown()
        state = .idle
    }

    private func fileEnded() async {
        // The recognizer has delivered its last final; wait for translations in flight, then the spoken output.
        if translationsInFlight > 0 { await withCheckedContinuation { translationWaiters.append($0) } }
        if let queue { await queue.waitUntilIdle() }
        await playback.drain()
        fileDone?.resume()
        fileDone = nil
    }

    /// Runs one recording through the pipeline and returns the captions when it ends (the self-test).
    public func run(file: URL) async -> [LiveCaption] {
        await start(source: .file(file))
        guard case .listening = state else { return captions }
        await withCheckedContinuation { continuation in fileDone = continuation }
        await stop()
        return captions
    }

    private func teardown() async {
        feeding?.cancel(); feeding = nil
        capture.stop()
        if let recognition { await recognition.cancel() }
        recognition = nil
        listening?.cancel(); listening = nil
        if let queue { await queue.stop() }
        queue = nil
        playback.stop()
        if let engine { await engine.shutdown() }
        engine = nil
        engineStatus = "Engine stopped"
        inputLevel = 0; outputLevel = 0
    }

    /// Best effort on the way out of the process: stop audio now; helpers exit when their stdin closes.
    public func terminateNow() {
        feeding?.cancel(); listening?.cancel()
        capture.stop(); playback.stop()
        if let engine { Task.detached { await engine.terminate() } }
    }
}
