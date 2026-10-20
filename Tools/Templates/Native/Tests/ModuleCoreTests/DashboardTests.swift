import XCTest
@testable import ModuleCore
final class DashboardTests: XCTestCase {
    func testOfflineAndBoundsPreventChanges() throws {
        var state = DemoState(count: 999)
        state.apply("increment"); XCTAssertEqual(state.count, 999)
        state.available = false; state.apply("reset"); XCTAssertEqual(state.count, 999)
        XCTAssertTrue(state.snapshot(title: "Demo", cards: true).displayActions.allSatisfy { !$0.enabled })
        XCTAssertThrowsError(try DemoState(count: -1).validate())
    }
    func testBothHostPresentationsValidateAndKeepReview() throws {
        let state = DemoState(count: 3)
        for cards in [false, true] {
            let snapshot = state.snapshot(title: "Demo", cards: cards)
            try snapshot.validate()
            XCTAssertNotNil(snapshot.enabledDisplayAction("reset")?.confirmation)
        }
        var next = state; next.apply("unknown"); XCTAssertEqual(state, next)
        next.apply("reset"); XCTAssertEqual(next.count, 0)
    }
}
