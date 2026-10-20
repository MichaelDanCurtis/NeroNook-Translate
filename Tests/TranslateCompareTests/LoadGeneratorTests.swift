import XCTest
import TranslateEngineClient
@testable import TranslateCompare

final class LoadGeneratorTests: XCTestCase {
    private var fake: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TranslateEngineClientTests/Fixtures/fake-engine.py")
    }

    func testStartAndStopAccountForEverySynthesis() async throws {
        let model = FileManager.default.temporaryDirectory.appendingPathComponent("translate-fake-\(UUID().uuidString)/burst")
        let engine = try await EngineClient.launch(engine: fake, model: model, timeout: 10)
        let load = LoadGenerator(engine: engine, slot: "generic", text: "x")
        await load.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        let summary = await load.stop()
        XCTAssertGreaterThan(summary.syntheses, 0)
        XCTAssertEqual(summary.errors, 0)
        XCTAssertTrue(summary.valid)
        XCTAssertEqual(summary.audioSeconds, (Double(summary.syntheses) * 200 / 24_000 * 10).rounded() / 10, accuracy: 0.11)
        let again = await load.stop()
        XCTAssertEqual(again.syntheses, summary.syntheses, "stop is idempotent")
        await engine.shutdown()
    }

    func testAFailingEngineMarksThePassInvalid() async throws {
        let model = FileManager.default.temporaryDirectory.appendingPathComponent("translate-fake-\(UUID().uuidString)/error-slot")
        let engine = try await EngineClient.launch(engine: fake, model: model, timeout: 10)
        let load = LoadGenerator(engine: engine, slot: "generic", text: "x")
        await load.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        let summary = await load.stop()
        XCTAssertEqual(summary.syntheses, 0)
        XCTAssertGreaterThan(summary.errors, 5)
        XCTAssertTrue(summary.stoppedEarly)
        XCTAssertFalse(summary.valid)
        await engine.shutdown()
    }
}
