import AVFoundation
import Foundation
import Speech
import TranslateAudio

public enum RecognitionEvent: Sendable {
    case partial(String)
    case final(String)
    case failed(String)
}

/// One Apple SpeechAnalyzer session fed with 16 kHz mono chunks. Volatile results refresh the caption;
/// final results commit a phrase (the plan's commit rule, with Apple's own endpointing for now).
public final class AppleRecognitionStream: @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let builder: AsyncStream<AnalyzerInput>.Continuation
    private let source: AVAudioFormat
    private var target: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let events: AsyncStream<RecognitionEvent>
    private let sink: AsyncStream<RecognitionEvent>.Continuation
    private var collector: Task<Void, Never>?
    public let locale: Locale

    /// Whether the locale's on-device assets are installed for this app. Assets are reserved per client, so
    /// the locale is reserved first (no download); an asset another process installed still shows as
    /// `supported` here until this app installs it.
    public static func assetsInstalled(locale: Locale) async -> Bool {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        _ = try? await AssetInventory.reserve(locale: locale)
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    /// Installs the locale's assets for this app (a system download the first time on a Mac; a quick
    /// registration when another client already holds them).
    public static func installAssets(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw LiveProblem("The speech assets for \(locale.identifier) did not install.") }
    }

    public init(locale: Locale, names: [String] = []) async throws {
        self.locale = locale
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (input, builder) = AsyncStream<AnalyzerInput>.makeStream()
        (events, sink) = AsyncStream<RecognitionEvent>.makeStream()
        guard let source = PCMBuffers.monoFloatFormat(sampleRate: 16_000) else { throw LiveProblem("No 16 kHz audio format.") }
        self.source = source
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw LiveProblem("Speech recognition for \(locale.identifier) is not installed on this Mac.")
        }
        if !names.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = names
            try await analyzer.setContext(context)
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw LiveProblem("Speech offers no audio format for \(locale.identifier).") }
        self.target = target
        if source != target { converter = AVAudioConverter(from: source, to: target) }
    }

    public var results: AsyncStream<RecognitionEvent> { events }

    public func start() async throws {
        collector = Task { [transcriber, sink] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    sink.yield(result.isFinal ? .final(text) : .partial(text))
                }
            } catch { sink.yield(.failed("\(error)")) }
            sink.finish()
        }
        try await analyzer.prepareToAnalyze(in: target)
        try await analyzer.start(inputSequence: input)
    }

    /// 16 kHz mono samples, in order. Called from the capture consumer, one chunk at a time.
    public func feed(_ samples: [Float]) {
        guard let buffer = PCMBuffers.buffer(samples, sampleRate: 16_000) else { return }
        do {
            if let converter, let target { builder.yield(AnalyzerInput(buffer: try PCMBuffers.convert(buffer, to: target, with: converter))) }
            else { builder.yield(AnalyzerInput(buffer: buffer)) }
        } catch { sink.yield(.failed("Audio conversion failed: \(error)")) }
    }

    /// Ends input and lets the analyzer finalize what it holds; the results stream then ends.
    public func finish() async {
        builder.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await collector?.value
    }

    /// Stops at once, dropping whatever is pending.
    public func cancel() async {
        builder.finish()
        await analyzer.cancelAndFinishNow()
        collector?.cancel()
        sink.finish()
    }
}
