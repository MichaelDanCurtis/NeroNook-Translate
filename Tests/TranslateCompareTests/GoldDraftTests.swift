import XCTest
@testable import TranslateCompare

final class GoldDraftTests: XCTestCase {
    func testSentencesSplitOnStopsButNotInsideNumbers() {
        XCTAssertEqual(GoldDraft.sentences("We tested version 3.4.1, then rolled back. Is that right? Yes! Fine"),
                       ["We tested version 3.4.1, then rolled back.", "Is that right?", "Yes!", "Fine"])
        XCTAssertEqual(GoldDraft.sentences("我们十点半见。可以吗？好！"), ["我们十点半见。", "可以吗？", "好！"])
        XCTAssertEqual(GoldDraft.sentences("   "), [])
    }
}
