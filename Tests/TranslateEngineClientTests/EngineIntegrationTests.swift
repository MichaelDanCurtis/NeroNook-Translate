import XCTest
@testable import TranslateEngineClient

/// Drives the real engine when a release build and the imported checkpoint exist; skips otherwise.
/// Runs under ten seconds warm. Not a measurement; the receipts come from `TranslateCheck --engine`.
final class EngineIntegrationTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private var engine: URL { root.appendingPathComponent("Engine/.build/release/TranslateEngine") }
    private var voices: URL { root.appendingPathComponent("Fixtures/Voices") }
    private var model: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NeroNookPlugins/cafe.nero.plugin.translate/Models/Qwen3-TTS-12Hz-1.7B-Base-8bit-e7dd0585652209fa0d7783659aad4e8a324de11c")
    }

    private func transcript(_ name: String) throws -> String {
        try String(contentsOf: voices.appendingPathComponent(name + ".txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func collect(_ client: EngineClient, id: String = UUID().uuidString, slot: String, text: String, cancelAtFirstAudio: Bool = false) async throws -> (done: SynthesisDone, bytes: Int, chunksAfterCancel: Int) {
        var done: SynthesisDone?
        var bytes = 0
        var chunksAfterCancel = 0
        var sentCancel = false
        for try await event in await client.synthesize(id: id, slot: slot, text: text) {
            switch event {
            case .audio(let data, let rate):
                XCTAssertEqual(rate, client.sampleRate)
                bytes += data.count
                if cancelAtFirstAudio {
                    if sentCancel { chunksAfterCancel += 1 } else { sentCancel = true; try await client.cancel(id: id) }
                }
            case .done(let stats): done = stats
            }
        }
        return (try XCTUnwrap(done), bytes, chunksAfterCancel)
    }

    func testTwoVoicesBothDirectionsCancelAndRecovery() async throws {
        guard FileManager.default.isExecutableFile(atPath: engine.path) else { throw XCTSkip("Build the engine first: swift build -c release --package-path Engine") }
        guard FileManager.default.fileExists(atPath: model.appendingPathComponent("config.json").path) else { throw XCTSkip("Import the Qwen Base checkpoint first (docs/PROVENANCE.md)") }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("translate-engine-test-\(UUID().uuidString).log")
        let client = try await EngineClient.launch(engine: engine, model: model, log: log)
        defer { Task { await client.shutdown() }; try? FileManager.default.removeItem(at: log) }

        // Unknown slot fails only that request; the engine keeps serving.
        do { for try await _ in await client.synthesize(slot: "remote", text: "hello") {}; XCTFail("Expected an error for an unprepared slot") } catch {}
        try await client.ping()

        let generic = try await client.prepareVoice(slot: "generic", reference: voices.appendingPathComponent("generic-en.wav"), transcript: try transcript("generic-en"), language: "English")
        let local = try await client.prepareVoice(slot: "local", reference: voices.appendingPathComponent("local-en.wav"), transcript: try transcript("local-en"), language: "Spanish")
        XCTAssertEqual(generic.language, "english"); XCTAssertEqual(local.language, "spanish")
        XCTAssertLessThan(generic.prepareMs, 2000); XCTAssertLessThan(local.prepareMs, 2000)

        // English reference speaking Spanish (the local lane), then the generic English voice.
        let spanish = try await collect(client, slot: "local", text: "Gracias, eso me funciona.")
        XCTAssertFalse(spanish.done.discarded)
        XCTAssertEqual(spanish.bytes / 4, spanish.done.forwardedFrames)
        XCTAssertEqual(spanish.done.frames, spanish.done.forwardedFrames)
        XCTAssertGreaterThan(spanish.done.audioSeconds, 0.5)
        XCTAssertLessThan(spanish.done.realTimeFactor, 0.8, "Well faster than real time on the reference Mac")

        // Finish-and-discard: cancel after the first chunk; the engine finishes, forwards at most the chunk in flight, and reports the waste.
        let discarded = try await collect(client, slot: "generic", text: String(repeating: "Thanks, that works for me. ", count: 4), cancelAtFirstAudio: true)
        XCTAssertTrue(discarded.done.discarded)
        XCTAssertNotNil(discarded.done.wastedMs)
        XCTAssertGreaterThan(discarded.done.frames, discarded.done.forwardedFrames, "Generation continued after the cancel")
        XCTAssertLessThanOrEqual(discarded.chunksAfterCancel, 1)

        // The same slot works again right after a discard, and a cancel before start drops the unit at once.
        let again = try await collect(client, slot: "generic", text: "Thanks, that works for me.")
        XCTAssertFalse(again.done.discarded); XCTAssertGreaterThan(again.done.audioSeconds, 0.3)
        let early = UUID().uuidString
        try await client.cancel(id: early)   // unknown yet: the engine ignores it, as the registry only records known ids
        let earlyRun = try await collect(client, id: early, slot: "generic", text: "Thanks.")
        XCTAssertFalse(earlyRun.done.discarded, "A cancel for an unknown id is not remembered")

        let stats = try await client.stats()
        XCTAssertGreaterThan(stats.residentBytes, 1_000_000_000)

        // Identity-cache regression: two different references must never share a cached context.
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains("Returning cached context"), "The library's identity-keyed cache aliased two references")
    }
}
