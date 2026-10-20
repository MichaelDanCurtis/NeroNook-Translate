import XCTest
@testable import TranslateEngineClient

/// `HelperClient` against the fake engine: an oversized request, a stalled reply, and nested numbers.
final class HelperClientTests: XCTestCase {
    private var fake: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-engine.py") }
    private func mode(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("translate-fake-\(UUID().uuidString)/\(name)") }

    func testOversizedRequestFailsCleanlyAndTheHelperStaysUsable() async throws {
        let client = try await HelperClient.launch(helper: fake, arguments: ["--model", mode("burst").path], timeout: 10)
        do {
            _ = try await client.request(["type": "ping"], payload: Data(count: EngineFrame.maxPayloadBytes + 1))
            XCTFail("an oversized frame must throw")
        } catch { XCTAssert("\(error)".contains("exceeds its limit"), "\(error)") }
        let pong = try await client.request(["type": "ping"], timeout: 10)
        XCTAssertEqual(pong.type, "pong", "the helper was never told about the bad frame")
        await client.shutdown()
    }

    func testDeadlineFailsOnlyTheStalledRequest() async throws {
        let client = try await HelperClient.launch(helper: fake, arguments: ["--model", mode("slowping").path], timeout: 10)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await client.request(["type": "ping"], timeout: 0.3)
            XCTFail("a reply after the deadline must not count")
        } catch { XCTAssert("\(error)".contains("No reply within"), "\(error)") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.0)
        let stats = try await client.request(["type": "stats"], timeout: 10)   // queued behind the slow ping; the late pong is dropped
        XCTAssertEqual(stats.type, "stats")
        XCTAssertEqual(stats.int("residentBytes"), 12345)
        await client.shutdown()
    }

    func testWholeNumberTimesReadAsSeconds() throws {
        XCTAssertEqual(ASRClient.seconds(0), 0)
        XCTAssertEqual(ASRClient.seconds(1.5), 1.5)
        XCTAssertEqual(ASRClient.seconds(nil), -1)
        let frame = try EngineFrame.encode(["type": "transcript", "id": "a", "segments": [["text": "hi", "start": 0, "end": 1.5]]])
        let message = try XCTUnwrap(try EngineFrame.Reader().feed(frame).first)
        let segment = try XCTUnwrap((message.header["segments"] as? [[String: Any]])?.first)
        XCTAssertEqual(ASRClient.seconds(segment["start"]), 0)
        XCTAssertEqual(ASRClient.seconds(segment["end"]), 1.5)
    }
}
