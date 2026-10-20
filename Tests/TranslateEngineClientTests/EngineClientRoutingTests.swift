import Darwin
import XCTest
@testable import TranslateEngineClient

/// Exercises `EngineClient` against a fake engine that speaks the protocol without a model, so reply
/// routing, ordering and failure handling are tested in milliseconds.
final class EngineClientRoutingTests: XCTestCase {
    private var fake: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-engine.py")
    }
    private func mode(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("translate-fake-\(UUID().uuidString)/\(name)") }

    func testBurstOfAudioArrivesCompleteAndInOrderBeforeDone() async throws {
        let client = try await EngineClient.launch(engine: fake, model: mode("burst"), timeout: 10)
        defer { Task { await client.shutdown() } }
        XCTAssertEqual(client.sampleRate, 24000)
        for _ in 0..<5 {   // repeated to give any ordering race a chance to show
            var chunks: [Float] = []
            var done: SynthesisDone?
            for try await event in await client.synthesize(slot: "generic", text: "x") {
                switch event {
                case .audio(let data, _): chunks.append(data.withUnsafeBytes { $0.load(as: Float.self) })
                case .done(let stats): done = stats
                }
            }
            XCTAssertEqual(chunks, (0..<50).map(Float.init), "Every chunk, in sequence, before done")
            XCTAssertEqual(done?.forwardedFrames, 200)
            XCTAssertEqual(done?.discarded, false)
        }
        try await client.ping()
        let stats = try await client.stats()
        XCTAssertEqual(stats.residentBytes, 12345)
    }

    func testCancelIsReflectedInDone() async throws {
        let client = try await EngineClient.launch(engine: fake, model: mode("burst"), timeout: 10)
        defer { Task { await client.shutdown() } }
        let id = UUID().uuidString
        try await client.cancel(id: id)
        var done: SynthesisDone?
        for try await event in await client.synthesize(id: id, slot: "generic", text: "x") { if case .done(let stats) = event { done = stats } }
        XCTAssertEqual(done?.discarded, true)
        XCTAssertEqual(done?.wastedMs, 1)
    }

    func testRequestErrorFailsOnlyThatStream() async throws {
        let client = try await EngineClient.launch(engine: fake, model: mode("error-slot"), timeout: 10)
        defer { Task { await client.shutdown() } }
        do {
            for try await _ in await client.synthesize(slot: "nope", text: "x") {}
            XCTFail("Expected the stream to throw")
        } catch {
            XCTAssertTrue("\(error)".contains("not prepared"))
        }
        try await client.ping()   // the client is still usable
    }

    func testEngineDeathFailsOutstandingWorkWithoutASignal() async throws {
        let client = try await EngineClient.launch(engine: fake, model: mode("die"), timeout: 10)
        var received = 0
        do {
            for try await event in await client.synthesize(slot: "generic", text: "x") { if case .audio = event { received += 1 } }
            XCTFail("Expected the stream to throw when the engine dies")
        } catch {
            XCTAssertEqual(received, 2, "Frames sent before the death are delivered")
        }
        // Writing to the dead engine must raise an error here, not SIGPIPE the test process.
        do { try await client.ping(); XCTFail("Expected an error") } catch {}
        do { try await client.cancel(id: "any"); } catch {}
        do { _ = try await client.stats(); XCTFail("Expected an error") } catch {}
    }

    func testLaunchTimeoutTerminatesTheHelper() async throws {
        let directory = mode("noready")
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await EngineClient.launch(engine: fake, model: directory, timeout: 1.5)
            XCTFail("Expected launch to time out")
        } catch {
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 10)
        }
        // The fake wrote its pid before sleeping; it must be gone shortly after the timeout.
        var pid: Int32?
        for _ in 0..<50 {
            if let text = try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8), let value = Int32(text) { pid = value; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let helper = try XCTUnwrap(pid)
        var gone = false
        for _ in 0..<50 {
            if kill(helper, 0) != 0 && errno == ESRCH { gone = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(gone, "The helper process was terminated, not leaked")
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }
}
