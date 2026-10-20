import XCTest
import TranslateEngineClient
@testable import TranslateCompare

final class CorpusAndReceiptTests: XCTestCase {
    func testCorpusLoaderPairsRawAndCodecCopiesWithTheSameGold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corpus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["raw/en", "codec/en", "gold/en", "raw/es"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        let tone = [Float](repeating: 0, count: 1600)
        try AudioDecoding.writeWAV(tone, sampleRate: 16_000, to: root.appendingPathComponent("raw/en/scripted.wav"))
        try AudioDecoding.writeWAV(tone, sampleRate: 16_000, to: root.appendingPathComponent("codec/en/scripted.wav"))
        try AudioDecoding.writeWAV(tone, sampleRate: 16_000, to: root.appendingPathComponent("raw/en/natural-1.wav"))
        try AudioDecoding.writeWAV(tone, sampleRate: 16_000, to: root.appendingPathComponent("raw/es/orphan.wav"))   // no gold text: skipped
        try "Line one.\nLine two.\n".write(to: root.appendingPathComponent("gold/en/scripted.txt"), atomically: true, encoding: .utf8)
        try "Just talking.".write(to: root.appendingPathComponent("gold/en/natural-1.txt"), atomically: true, encoding: .utf8)
        try #"{"checks": [{"category": "name", "sentence": 1, "accept": ["ana"]}]}"#.write(to: root.appendingPathComponent("gold/en/scripted.checks.json"), atomically: true, encoding: .utf8)

        let items = try CorpusLoader.load(corpus: root, languages: ["en", "es"])
        XCTAssertEqual(items.map(\.id), ["en/natural-1", "en/scripted", "en/scripted@codec"])
        XCTAssertEqual(items.map(\.kind), ["natural", "scripted", "codec"])
        XCTAssertEqual(items[2].checks.count, 1)
        XCTAssertEqual(items[1].referenceLines, ["Line one.", "Line two."])
    }

    func testFixtureVoicesLoadAsFixtureItems() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Voices")
        let items = try CorpusLoader.loadFixtures(fixtures, languages: ["en", "es"])
        XCTAssertEqual(items.map(\.id), ["fixture/generic-en", "fixture/local-en", "fixture/remote-es"])
        XCTAssert(items.allSatisfy { $0.kind == "fixture" && !$0.reference.isEmpty })
    }

    func testListeningSheetRevealsNoVariantOrInterval() {
        let clips = ["base-1.7b-8bit", "base-0.6b-8bit"].flatMap { variant in [0.32, 0.16].map { interval in
            ListeningSet.Clip(id: UUID().uuidString.prefix(6).lowercased(), variant: variant, voice: "local-en", voiceLanguage: "en", language: "es", sentence: 1, text: "Hola, Marisol.",
                              streamingInterval: interval, underRecognition: false, firstAudioMs: 100, generationMs: 500, audioSeconds: 2, realTimeFactor: 0.25, file: "clips/x.wav") } }
        let sheet = ListeningSet.sheet(clips)
        XCTAssertFalse(sheet.contains("base-"), sheet)
        XCTAssertFalse(sheet.contains("0.32") || sheet.contains("0.16"), sheet)
        XCTAssert(sheet.contains("| local-en | es | Hola, Marisol. |"))
        XCTAssertEqual(sheet.components(separatedBy: "| local-en |").count - 1, 4)
    }

    func testProgramSDKStampIsReadable() throws {
        let stamp = try XCTUnwrap(BuildStamp.programSDKVersion())
        XCTAssertNotNil(stamp.range(of: #"^\d+\.\d+$"#, options: .regularExpression), stamp)
        XCTAssertTrue(BuildStamp.programSDK(atLeast: 1))
        XCTAssertFalse(BuildStamp.programSDK(atLeast: 999))
    }

    func testSummaryTablesAndReviewSheetSkipUnderLoadDuplicates() {
        let rate = ErrorRate(errors: 1, total: 10)
        let recognition = [false, true].map { CompareRunner.RecognitionRow(recognizer: "nemotron", item: "en/scripted", language: "en", kind: "scripted", underLoad: $0, audioSeconds: 60, ms: 3000, realTimeFactor: 0.05,
                                                                              errorRate: rate, checksPassed: 9, checksTotal: 10, byCategory: ["name": "3/3", "number": "2/3"], hypothesis: "x", detectedLanguage: nil, residentBytesAfter: 1_048_576 * 900, error: nil) }
        let phrase = CompareRunner.PhraseResult(index: 1, startSeconds: 0, seconds: 4, partialDelayMs: 700, finalDelayMs: 300, prefixRunMeanMs: nil, prefixRunMaxMs: nil, text: "x")
        let paced = [CompareRunner.PacedRow(recognizer: "nemotron", item: "en/scripted", language: "en", kind: "scripted", underLoad: false, audioSeconds: 60, phrases: [phrase], errorRate: rate, checksPassed: 9, checksTotal: 10,
                                            meanFinalDelayMs: 300, p90FinalDelayMs: 300, maxFinalDelayMs: 300, meanPartialDelayMs: 700, prefixRunMeanMs: nil, prefixRunMaxMs: nil, coverage: 0.9, residentBytesAfter: nil, error: nil)]
        let translation = [false, true].map { CompareRunner.TranslationRow(translator: "qwen3.5-2b-4bit", item: "en/scripted", from: "en", to: "es", line: 1, underLoad: $0, source: "Hi", output: "Hola", ms: 120, firstTokenMs: 40, withContext: false, error: nil) }
        let receipt = CompareRunner.Receipt(date: "2026-10-20", machine: "Mac16,5", build: ["sdkStamp": "27.0"], settings: ["chunkMs": "560"], models: ["nemotron": "folder"], corpus: "test", items: ["en/scripted"],
                                            recognition: recognition, translation: translation, paced: paced,
                                            load: ["recognition": LoadGenerator.Summary(syntheses: 4, audioSeconds: 30, generationMs: 9000, meanFirstAudioMs: 150, realTimeFactor: 0.3, errors: 0),
                                                   "paced": LoadGenerator.Summary(syntheses: 1, audioSeconds: 5, generationMs: 1500, meanFirstAudioMs: 150, realTimeFactor: 0.3, errors: 6, stoppedEarly: true)],
                                            resources: ["recognition": PassResources(wallSeconds: 12.5, processes: [ProcessSample(process: "asr-nemotron", cpuSeconds: 3.1, cpuPercent: 25, footprintMB: 870, peakFootprintMB: 900, mlxActiveMB: 600, mlxPeakMB: 700, mlxCacheMB: 10)],
                                                                                    gpu: GPUSample(meanDevicePercent: 40, maxDevicePercent: 90, meanRendererPercent: 35, samples: 50, inUseMemoryMB: 2500))], notes: ["n"])
        let summary = CompareRunner.summary(receipt)
        XCTAssert(summary.contains("| nemotron | en/scripted | – | 10.0% (1/10) | 9/10 | 3/3 | 2/3 | – | – | – | 3000 ms / 60.0 s | 0.05 |"), summary)
        XCTAssert(summary.contains("| nemotron | en/scripted | TTS | 10.0% (1/10)"), summary)
        XCTAssert(summary.contains("| nemotron | en/scripted | – | 1 | 90% | 10.0% | 9/10 | 300 / 300 / 300 | 700 | – |"), summary)
        XCTAssert(summary.contains("| recognition | 4 | 30.0 | 0.3 | 150 | 0 | yes |"), summary)
        XCTAssert(summary.contains("| paced | 1 | 5.0 | 0.3 | 150 | 6 | no |"), summary)
        XCTAssert(summary.contains("sdkStamp 27.0"), summary)
        XCTAssert(summary.contains("- nemotron: `folder`"), summary)
        XCTAssert(summary.contains("| recognition | 12.5 | 40% / 90% (50 samples) | asr-nemotron | 3.1 | 25 | 870.0 | 900.0 | 600.0 / 700.0 |"), summary)
        XCTAssert(summary.contains("| nemotron | – | 60.0 | 3000 | 900 |"), "footprint: ms per minute of speech\n" + summary)
        let sheet = CompareRunner.reviewSheet(receipt)
        XCTAssertEqual(sheet.components(separatedBy: "| qwen3.5-2b-4bit |").count - 1, 1, "under-load rows are the same model; rated once")
    }
}
