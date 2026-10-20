import XCTest
@testable import TranslateCore

final class CaptionWindowTests: XCTestCase {
    private func entry(_ id: UUID = UUID(), lane: Direction = .incoming, text: String = "hola", provisional: Bool) -> CaptionEntry {
        CaptionEntry(utteranceID: id, lane: lane, speaker: lane == .incoming ? .other : .me, sourceLanguage: "es-ES", targetLanguage: "en-US",
                     sourceStart: 1, original: text, provisional: provisional)
    }

    func testFinalReplacesProvisionalInPlace() throws {
        var window = CaptionWindow()
        let id = UUID()
        window.upsert(entry(id, text: "ho", provisional: true))
        window.upsert(entry(UUID(), text: "other", provisional: true))
        var final = entry(id, text: "hola", provisional: false)
        final.translated = "hello"; final.translatedRev = 1; final.synthesis = .played
        window.upsert(final)
        let lane = window.entries[.incoming]!
        XCTAssertEqual(lane.count, 2)
        XCTAssertEqual(lane[0].original, "hola")
        XCTAssertFalse(lane[0].provisional)
        XCTAssertEqual(window.entry(id)?.translated, "hello")
    }

    func testPerLaneLimitDropsOldest() {
        var window = CaptionWindow(perLane: 3)
        let ids = (0..<5).map { _ in UUID() }
        for (index, id) in ids.enumerated() { window.upsert(entry(id, text: "\(index)", provisional: false)) }
        XCTAssertEqual(window.entries[.incoming]!.map(\.utteranceID), Array(ids[2...]))
        XCTAssertTrue(window.entries[.outgoing]!.isEmpty)
    }

    func testStateFitsTheLimitByTrimmingOldest() throws {
        var window = CaptionWindow(perLane: 400)
        for index in 0..<400 { window.upsert(entry(text: String(repeating: "x", count: 500) + "\(index)", provisional: false)) }
        for index in 0..<40 { window.upsert(entry(lane: .outgoing, text: "short \(index)", provisional: false)) }
        let data = try window.state()
        XCTAssertLessThanOrEqual(data.count, Bounds.captionStateBytes)
        let state = try SessionJSON.decoder().decode(CaptionWindow.State.self, from: data)
        XCTAssertEqual(state.display, .both)
        XCTAssertEqual(state.lanes["outgoing"]?.count, 40, "The shorter lane keeps everything")
        XCTAssertLessThan(state.lanes["incoming"]?.count ?? 0, 400)
        XCTAssertEqual(state.lanes["incoming"]?.last?.original.suffix(3), "399", "The newest entries survive")
    }

    func testDisplayChoiceAndErrorKindsSerialize() throws {
        var window = CaptionWindow(display: .original, visible: false)
        var failed = entry(provisional: false)
        failed.error = .translation
        window.upsert(failed)
        let state = try SessionJSON.decoder().decode(CaptionWindow.State.self, from: try window.state())
        XCTAssertEqual(state.display, .original)
        XCTAssertEqual(state.lanes["incoming"]?.first?.error, .translation)
        XCTAssertFalse(window.visible)
    }
}
