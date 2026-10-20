import XCTest
@testable import TranslateEngineClient

final class EngineFrameTests: XCTestCase {
    func testRoundTripThroughArbitrarySplits() throws {
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        let one = try EngineFrame.encode(["type": "audio", "id": "a", "seq": 3, "sampleRate": 24000], payload: payload)
        let two = try EngineFrame.encode(["type": "done", "id": "a", "frames": 123, "discarded": true, "rtf": 0.33])
        let bytes = one + two
        for split in [1, 3, 4, 5, 17, 100, bytes.count - 1, bytes.count] {
            let reader = EngineFrame.Reader()
            var messages: [EngineFrame.Message] = []
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + split, bytes.count)
                messages += try reader.feed(bytes[offset..<end])
                offset = end
            }
            XCTAssertEqual(messages.count, 2, "split \(split)")
            XCTAssertEqual(messages[0].type, "audio"); XCTAssertEqual(messages[0].int("seq"), 3); XCTAssertEqual(messages[0].payload, payload)
            XCTAssertEqual(messages[1].type, "done"); XCTAssertEqual(messages[1].int("frames"), 123)
            XCTAssertEqual(messages[1].bool("discarded"), true); XCTAssertEqual(messages[1].double("rtf"), 0.33)
            XCTAssertTrue(messages[1].payload.isEmpty)
        }
    }

    func testZeroAndOneStayIntegersAndBooleansStayBooleans() throws {
        let line = try EngineFrame.encode(["type": "audio", "seq": 0, "one": 1, "flag": true, "off": false, "ratio": 0.5, "big": 2_417_320_525])
        let message = try XCTUnwrap(try EngineFrame.Reader().feed(line).first)
        XCTAssertEqual(message.int("seq"), 0)
        XCTAssertEqual(message.int("one"), 1)
        XCTAssertNil(message.bool("seq"), "0 is a number, not false")
        XCTAssertEqual(message.bool("flag"), true)
        XCTAssertEqual(message.bool("off"), false)
        XCTAssertNil(message.int("flag"), "true is not 1")
        XCTAssertEqual(message.double("ratio"), 0.5)
        XCTAssertEqual(message.int("ratio"), 0, "Integer view of a fraction truncates, by design")
        XCTAssertEqual(message.int("big"), 2_417_320_525)
    }

    func testBoundsAreEnforced() throws {
        XCTAssertThrowsError(try EngineFrame.encode(["type": "x"], payload: Data(count: EngineFrame.maxPayloadBytes + 1)))
        var oversized = Data()
        oversized.append(contentsOf: withUnsafeBytes(of: UInt32(EngineFrame.maxHeaderBytes + 1).bigEndian, Array.init))
        oversized.append(Data(count: 8))
        XCTAssertThrowsError(try EngineFrame.Reader().feed(oversized))
        var notObject = Data()
        let json = Data("[1,2]".utf8)
        notObject.append(contentsOf: withUnsafeBytes(of: UInt32(json.count).bigEndian, Array.init)); notObject.append(json)
        notObject.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian, Array.init))
        XCTAssertThrowsError(try EngineFrame.Reader().feed(notObject))
    }

    func testDecodesWavToMonoFloat32AtTargetRate() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Voices/generic-en.wav")
        let samples = try EngineClient.decode(fixture, sampleRate: 24000)
        XCTAssertGreaterThan(Double(samples.count) / 24000, 3, "The fixture is longer than the 3 s minimum reference")
        XCTAssertLessThan(Double(samples.count) / 24000, 30)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertGreaterThan(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count), 1e-6, "Not silent")
    }
}
