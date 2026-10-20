import XCTest
@testable import TranslateCompare

final class PhraseSplitterTests: XCTestCase {
    func burst(_ seconds: Double, amplitude: Float = 0.3) -> [Float] { (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -amplitude...amplitude) } }
    func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

    func testTwoBurstsBecomeTwoPhrasesWithMargins() {
        let samples = burst(1.5) + silence(1.5) + burst(2)
        let phrases = PhraseSplitter.split(samples)
        XCTAssertEqual(phrases.count, 2)
        XCTAssertEqual(phrases[0].start, 0)
        XCTAssert((1.5...2.0).contains(Double(phrases[0].end) / 16_000), "\(phrases[0])")
        XCTAssert((2.5...3.0).contains(Double(phrases[1].start) / 16_000), "\(phrases[1])")
        XCTAssertEqual(phrases[1].end, samples.count, "speech up to the end keeps the end")
        XCTAssertLessThanOrEqual(phrases[0].end, phrases[1].start + 16_000 / 50 * 7)
    }

    func testSilenceIsOnePhraseAndShortBurstsJoinTheNext() {
        XCTAssertEqual(PhraseSplitter.split(silence(3)), [PhraseSplitter.Phrase(start: 0, end: 48_000)])
        XCTAssertEqual(PhraseSplitter.split([]), [])
        let joined = PhraseSplitter.split(burst(0.4) + silence(1.5) + burst(2))
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined[0].start, 0)
    }

    func testTrailingSilenceIsNotFedAndQuietSpeechIsFound() {
        let trailing = PhraseSplitter.split(burst(2) + silence(10))
        XCTAssertEqual(trailing.count, 1)
        XCTAssert((2.0...2.5).contains(Double(trailing[0].end) / 16_000), "\(trailing[0])")
        XCTAssertLessThan(PhraseSplitter.coverage(trailing, total: 12 * 16_000), 0.25)
        let quiet = PhraseSplitter.split(burst(1.5, amplitude: 0.003) + silence(1.5) + burst(2, amplitude: 0.003))   // about -50 dBFS
        XCTAssertEqual(quiet.count, 2, "the gate follows the clip's own level, not an absolute floor")
    }

    func testLongSpeechIsCutIntoBoundedOrderedPhrases() {
        let samples = burst(40)
        let phrases = PhraseSplitter.split(samples)
        XCTAssertGreaterThanOrEqual(phrases.count, 3)
        var previousEnd = 0
        for phrase in phrases {
            XCTAssertLessThanOrEqual(Double(phrase.end - phrase.start) / 16_000, 15.3)
            XCTAssertGreaterThanOrEqual(phrase.start, max(0, previousEnd - 16_000 / 50 * 7))
            XCTAssertLessThan(phrase.start, phrase.end)
            previousEnd = phrase.end
        }
        XCTAssertEqual(phrases.first?.start, 0)
        XCTAssertGreaterThan(PhraseSplitter.coverage(phrases, total: samples.count), 0.95)
    }
}
