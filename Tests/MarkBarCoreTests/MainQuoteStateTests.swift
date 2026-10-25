import XCTest
@testable import MarkBarCore

final class MainQuoteStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func quote(_ price: Decimal, seconds: TimeInterval, contract: Contract = .btc) -> MarkQuote {
        MarkQuote(contract: contract, price: price,
                  dataTime: start.addingTimeInterval(seconds),
                  receivedAt: start.addingTimeInterval(seconds + 0.1))
    }

    func testStrictAdvancementAndRouteGapAreIndependentFromFreshness() {
        var book = MainQuoteStateBook()
        book.replaceContracts([.btc], preserveQuotes: false, gap: .startup, now: start)

        let first = book.apply(quote(100, seconds: 1), route: .restFallback, now: start.addingTimeInterval(1))
        XCTAssertNotNil(first)
        XCTAssertTrue(first?.continuity.possiblyMissed == true)
        XCTAssertNil(book.apply(quote(101, seconds: 1), route: .restFallback,
                                  now: start.addingTimeInterval(2)))

        let streamed = book.apply(quote(102, seconds: 3), route: .webSocket,
                                  now: start.addingTimeInterval(3))
        XCTAssertNotNil(streamed)
        XCTAssertFalse(streamed?.continuity.possiblyMissed == true)
        let state = book.state(for: .btc, at: start.addingTimeInterval(10), staleAfter: 20)
        XCTAssertFalse(state.isStale)
        XCTAssertEqual(state.entry.quote?.price, 102)
    }

    func testRouteChangePreservesQuoteButAdvancesContinuityEpoch() {
        var book = MainQuoteStateBook()
        book.replaceContracts([.btc], preserveQuotes: false, gap: .startup, now: start)
        let initial = book.apply(quote(100, seconds: 1), route: .webSocket,
                                 now: start.addingTimeInterval(1))
        book.replaceContracts([.btc], preserveQuotes: true, gap: .routeChanged,
                              now: start.addingTimeInterval(2))
        let state = book.state(for: .btc, at: start.addingTimeInterval(2), staleAfter: 20)
        XCTAssertEqual(state.entry.quote?.price, 100)
        XCTAssertGreaterThan(state.continuityEpoch, initial?.continuityEpoch ?? 0)
        XCTAssertTrue(state.continuity.possiblyMissed)
    }

    func testRejectedRESTSampleDoesNotBreakWebSocketContinuity() {
        var book = MainQuoteStateBook()
        book.replaceContracts([.btc], preserveQuotes: false, gap: .startup, now: start)
        let streamed = book.apply(quote(102, seconds: 3), route: .webSocket,
                                  now: start.addingTimeInterval(3))

        XCTAssertNil(book.apply(quote(101, seconds: 2), route: .restFallback,
                                  now: start.addingTimeInterval(4)))

        let state = book.state(for: .btc, at: start.addingTimeInterval(4), staleAfter: 20)
        XCTAssertEqual(state.entry.quote?.price, 102)
        XCTAssertEqual(state.route, .webSocket)
        XCTAssertEqual(state.continuityEpoch, streamed?.continuityEpoch)
        XCTAssertFalse(state.continuity.possiblyMissed)
    }
}
