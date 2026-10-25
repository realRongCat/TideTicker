import Foundation
import XCTest
@testable import MarkBarCore

final class QuoteBookTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_941_600)

    private func quote(_ contract: Contract = .btc, price: Decimal = 83_195.2,
                       dataOffset: TimeInterval = 0, receivedOffset: TimeInterval = 0) -> MarkQuote {
        MarkQuote(contract: contract, price: price,
                  dataTime: start.addingTimeInterval(dataOffset),
                  receivedAt: start.addingTimeInterval(receivedOffset))
    }

    func testUnchangedPriceWithNewDataTimestampRemainsFresh() {
        var book = QuoteBook()
        XCTAssertTrue(book.apply(quote(), now: start))
        XCTAssertTrue(book.apply(quote(dataOffset: 15, receivedOffset: 15), now: start.addingTimeInterval(15)))
        XCTAssertFalse(book.entry(for: .btc).isStale(at: start.addingTimeInterval(30)))
    }

    func testDuplicateResponseCannotRenewExpiredQuote() {
        var book = QuoteBook()
        book.apply(quote(), now: start)
        XCTAssertFalse(book.apply(quote(receivedOffset: 25), now: start.addingTimeInterval(25)))
        XCTAssertTrue(book.entry(for: .btc).isStale(at: start.addingTimeInterval(25)))
        XCTAssertEqual(book.entry(for: .btc).quote?.receivedAt, start)
    }

    func testOutOfOrderResponseNeverOverwritesLatestValue() {
        var book = QuoteBook()
        book.apply(quote(price: 83_200, dataOffset: 10), now: start.addingTimeInterval(10))
        XCTAssertFalse(book.apply(quote(price: 83_000), now: start.addingTimeInterval(12)))
        XCTAssertEqual(book.entry(for: .btc).quote?.price, 83_200)
    }

    func testFailureRetainsPriceAndIsIsolatedByContract() {
        var book = QuoteBook()
        book.apply(quote(), now: start)
        book.apply(quote(.eth, price: 2_500.33), now: start)
        book.recordFailure(.btc, message: "连接超时")
        XCTAssertNotNil(book.entry(for: .btc).quote)
        XCTAssertEqual(book.entry(for: .btc).lastError, "连接超时")
        XCTAssertNil(book.entry(for: .eth).lastError)
        XCTAssertTrue(book.entry(for: .btc).isStale(at: start.addingTimeInterval(21)))
    }

    func testFutureTimestampAndZeroPriceAreRejected() {
        var book = QuoteBook()
        XCTAssertFalse(book.apply(quote(dataOffset: 120), now: start))
        XCTAssertFalse(book.apply(quote(price: 0), now: start))
        XCTAssertNil(book.entry(for: .btc).quote)
    }

    func testRecoveryClearsErrorWhenNewDataArrives() {
        var book = QuoteBook()
        book.apply(quote(), now: start)
        book.recordFailure(.btc, message: "连接超时")
        book.apply(quote(dataOffset: 25), now: start.addingTimeInterval(25))
        XCTAssertNil(book.entry(for: .btc).lastError)
        XCTAssertFalse(book.entry(for: .btc).isStale(at: start.addingTimeInterval(25)))
    }
}
