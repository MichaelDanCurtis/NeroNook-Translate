import XCTest
@testable import TranslateCore

final class SchedulerTests: XCTestCase {
    // MARK: Unit splitting

    func testShortTextIsOneUnit() {
        XCTAssertEqual(UnitSplitter.split("  Hola.  "), ["Hola."])
        XCTAssertEqual(UnitSplitter.split("   "), [])
    }

    func testSplitsAtSentencesWithinBound() {
        let sentence = String(repeating: "palabra ", count: 20).trimmingCharacters(in: .whitespaces) + "."   // ~160 bytes
        let text = [sentence, sentence, sentence].joined(separator: " ")
        let units = UnitSplitter.split(text, maxBytes: 300)
        XCTAssertEqual(units.count, 3)
        XCTAssertTrue(units.allSatisfy { $0.utf8.count <= 300 && $0.hasSuffix(".") })
    }

    func testOversizedSentenceFallsBackToClausesThenWords() {
        let clause = String(repeating: "x ", count: 60).trimmingCharacters(in: .whitespaces)   // 119 bytes
        let text = [clause, clause, clause, clause].joined(separator: ", ") + "."             // one sentence, ~485 bytes
        let units = UnitSplitter.split(text, maxBytes: 300)
        XCTAssertGreaterThan(units.count, 1)
        XCTAssertTrue(units.allSatisfy { $0.utf8.count <= 300 })
        XCTAssertEqual(units.joined(separator: " "), text, "Rejoined units equal the input exactly")
    }

    func testPunctuationInsideTokensNeverSplits() {
        let sentence = "We raised 1.5 million, met at 10:30, paid 1,000 e.g. in cash; see www.example.com for details."
        let text = Array(repeating: sentence, count: 4).joined(separator: " ")   // ~400 bytes, forces splitting
        let units = UnitSplitter.split(text, maxBytes: 120)
        XCTAssertGreaterThan(units.count, 1)
        XCTAssertEqual(units.joined(separator: " "), text)
        for unit in units {
            XCTAssertFalse(unit.hasPrefix("5 million") || unit.hasPrefix("30,") || unit.hasPrefix("000") || unit.hasPrefix("g."), unit)
        }
        XCTAssertEqual(UnitSplitter.split("Tabs\tand\nnewlines   collapse.", maxBytes: 9), ["Tabs and", "newlines", "collapse."])
    }

    func testOnlyAnOversizedWordIsCutMidWord() {
        let word = String(repeating: "ñ", count: 200)   // 400 bytes
        let units = UnitSplitter.split(word, maxBytes: 300)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units.joined(), word)
        XCTAssertTrue(units.allSatisfy { $0.utf8.count <= 300 })
    }

    func testMandarinPunctuationSplits() {
        let text = "我们明天见面。然后一起吃饭！好吗？"
        XCTAssertEqual(UnitSplitter.split(text, maxBytes: 24), ["我们明天见面。", "然后一起吃饭！", "好吗？"])
    }

    // MARK: Scheduling

    func testOldestCommittedPhraseFirstAcrossLanes() {
        let scheduler = SynthesisScheduler()
        let a = UUID(), b = UUID(), c = UUID()
        scheduler.enqueue(utteranceID: a, lane: .outgoing, text: "one", committedAt: 10, sourceSeconds: 2)
        scheduler.enqueue(utteranceID: b, lane: .incoming, text: "two", committedAt: 12, sourceSeconds: 2)
        scheduler.enqueue(utteranceID: c, lane: .incoming, text: "three", committedAt: 9, sourceSeconds: 2)
        let first = scheduler.next()
        XCTAssertEqual(first?.utteranceID, c)
        XCTAssertNil(scheduler.next(), "One executor: nothing starts while a unit runs")
        scheduler.finish(first!.id)
        XCTAssertEqual(scheduler.next()?.utteranceID, a)
    }

    func testTieGoesToIncomingAndPhraseUnitsStayInOrder() {
        let scheduler = SynthesisScheduler(maxUnitBytes: 12)
        let incoming = UUID(), outgoing = UUID()
        let units = scheduler.enqueue(utteranceID: incoming, lane: .incoming, text: "First part. Second part.", committedAt: 5, sourceSeconds: 3)
        scheduler.enqueue(utteranceID: outgoing, lane: .outgoing, text: "Other", committedAt: 5, sourceSeconds: 1)
        XCTAssertEqual(units.count, 2)
        let first = scheduler.next()!
        XCTAssertEqual(first.utteranceID, incoming); XCTAssertEqual(first.index, 0)
        scheduler.finish(first.id)
        // The second unit of the incoming phrase carries the same commit time, so it still precedes the outgoing tie.
        let second = scheduler.next()!
        XCTAssertEqual(second.utteranceID, incoming); XCTAssertEqual(second.index, 1)
        scheduler.finish(second.id)
        XCTAssertEqual(scheduler.next()?.utteranceID, outgoing)
    }

    func testStopDropsQueuedAndDiscardsRunningWithoutPreempting() {
        let scheduler = SynthesisScheduler()
        let a = UUID(), b = UUID(), other = UUID()
        scheduler.enqueue(utteranceID: a, lane: .outgoing, text: "a", committedAt: 1, sourceSeconds: 1)
        scheduler.enqueue(utteranceID: b, lane: .outgoing, text: "b", committedAt: 2, sourceSeconds: 1)
        scheduler.enqueue(utteranceID: other, lane: .incoming, text: "c", committedAt: 3, sourceSeconds: 1)
        let running = scheduler.next()!
        XCTAssertEqual(running.utteranceID, a)
        let result = scheduler.stop(.outgoing)
        XCTAssertEqual(result.dropped.map(\.utteranceID), [b])
        XCTAssertEqual(result.discarded?.id, running.id)
        XCTAssertFalse(scheduler.isCurrent(running), "Output of the running unit is discarded")
        XCTAssertTrue(scheduler.executorBusy, "Finish-and-discard: the executor is not pre-empted")
        XCTAssertNil(scheduler.next())
        scheduler.finish(running.id)
        let next = scheduler.next()
        XCTAssertEqual(next?.utteranceID, other)
        XCTAssertTrue(scheduler.isCurrent(next!), "The other lane's epoch is untouched")
        XCTAssertEqual(scheduler.epoch(.outgoing), 1)
        XCTAssertEqual(scheduler.epoch(.incoming), 0)
    }

    func testUnitsEnqueuedAfterStopAreCurrent() {
        let scheduler = SynthesisScheduler()
        _ = scheduler.stop(.incoming)
        let units = scheduler.enqueue(utteranceID: UUID(), lane: .incoming, text: "new", committedAt: 1, sourceSeconds: 1)
        XCTAssertTrue(scheduler.isCurrent(units[0]))
    }

    func testSkipToLiveDropsQueueButKeepsRunningAndEpoch() {
        let scheduler = SynthesisScheduler()
        scheduler.enqueue(utteranceID: UUID(), lane: .incoming, text: "a", committedAt: 1, sourceSeconds: 1)
        scheduler.enqueue(utteranceID: UUID(), lane: .incoming, text: "b", committedAt: 2, sourceSeconds: 1)
        let running = scheduler.next()!
        let omitted = scheduler.skipToLive(.incoming)
        XCTAssertEqual(omitted.count, 1)
        XCTAssertTrue(scheduler.isCurrent(running))
        XCTAssertEqual(scheduler.epoch(.incoming), 0)
    }

    func testBacklogLevels() {
        let scheduler = SynthesisScheduler()
        XCTAssertEqual(scheduler.backlog(.incoming, now: 100).level, .ok)
        scheduler.enqueue(utteranceID: UUID(), lane: .incoming, text: "a", committedAt: 99, sourceSeconds: 1)
        XCTAssertEqual(scheduler.backlog(.incoming, now: 100).level, .ok)
        scheduler.enqueue(utteranceID: UUID(), lane: .incoming, text: "b", committedAt: 99.5, sourceSeconds: 1)
        XCTAssertEqual(scheduler.backlog(.incoming, now: 100).level, .behind, "Two queued phrases is the soft bound")
        XCTAssertEqual(scheduler.backlog(.incoming, now: 100).phrases, 2)
        scheduler.enqueue(utteranceID: UUID(), lane: .incoming, text: "c", committedAt: 99.8, sourceSeconds: 19)
        XCTAssertEqual(scheduler.backlog(.incoming, now: 100).level, .over, "Queued source seconds reached the hard bound")
        XCTAssertEqual(scheduler.backlog(.outgoing, now: 100).level, .ok)
    }

    func testBacklogKeepsTheRemainingSecondsOfAPhraseAfterItsFirstUnitStarts() {
        let scheduler = SynthesisScheduler(maxUnitBytes: 12)
        let units = scheduler.enqueue(utteranceID: UUID(), lane: .incoming, text: "First part. Second part.", committedAt: 0, sourceSeconds: 6)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units.reduce(0) { $0 + $1.sourceSeconds }, 6, accuracy: 0.001, "Seconds are shared across the phrase's units")
        XCTAssertEqual(scheduler.backlog(.incoming, now: 1).queuedSeconds, 6, accuracy: 0.001)
        let running = scheduler.next()!
        let backlog = scheduler.backlog(.incoming, now: 1)
        XCTAssertEqual(backlog.queuedSeconds, 6 - running.sourceSeconds, accuracy: 0.001, "The unit still waiting keeps its share")
        XCTAssertEqual(backlog.runningSeconds, running.sourceSeconds, accuracy: 0.001)
        XCTAssertEqual(backlog.phrases, 1)
    }

    func testOldestAgeAloneCanTripBacklog() {
        let scheduler = SynthesisScheduler()
        scheduler.enqueue(utteranceID: UUID(), lane: .outgoing, text: "a", committedAt: 0, sourceSeconds: 1)
        XCTAssertEqual(scheduler.backlog(.outgoing, now: 7).level, .behind)
        XCTAssertEqual(scheduler.backlog(.outgoing, now: 21).level, .over)
    }

    func testStressStopThenStartOtherLaneKeepsSingleExecutor() {
        let scheduler = SynthesisScheduler()
        for round in 0..<100 {
            let lane: Direction = round % 2 == 0 ? .incoming : .outgoing
            let other: Direction = lane == .incoming ? .outgoing : .incoming
            scheduler.enqueue(utteranceID: UUID(), lane: lane, text: "running", committedAt: Double(round), sourceSeconds: 1)
            let running = scheduler.next()!
            _ = scheduler.stop(lane)
            scheduler.enqueue(utteranceID: UUID(), lane: other, text: "next", committedAt: Double(round) + 0.5, sourceSeconds: 1)
            XCTAssertNil(scheduler.next(), "round \(round): a discarded unit still owns the executor")
            scheduler.finish(running.id)
            let next = scheduler.next()!
            XCTAssertEqual(next.lane, other)
            XCTAssertTrue(scheduler.isCurrent(next))
            scheduler.finish(next.id)
            XCTAssertFalse(scheduler.executorBusy)
        }
    }
}
