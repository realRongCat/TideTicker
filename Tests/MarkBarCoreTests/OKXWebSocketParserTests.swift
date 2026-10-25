import XCTest
@testable import MarkBarCore

final class OKXWebSocketParserTests: XCTestCase {
    func testParsesSpotLastAndPerpetualMarkWithNativeIdentity() throws {
        let spot = Contract(exchange: .okx, instrumentID: "BTC-USDT", symbol: "BTC",
                            marketKind: .spot, quoteCurrency: "USDT",
                            settlementCurrency: "USDT", priceKind: .last)
        let now = Date(timeIntervalSince1970: 1_800_000_001)
        let lookup = [spot.instrumentID: spot, Contract.btc.instrumentID: Contract.btc]
        let ticker = Data(#"{"arg":{"channel":"tickers"},"data":[{"instId":"BTC-USDT","last":"80000.5","ts":"1800000000000"}]}"#.utf8)
        let mark = Data(#"{"arg":{"channel":"mark-price"},"data":[{"instId":"BTC-USDT-SWAP","markPx":"80001.25","ts":"1800000000100"}]}"#.utf8)

        XCTAssertEqual(try OKXWebSocketParser.quotes(ticker, contracts: lookup, receivedAt: now).first?.price, Decimal(string: "80000.5"))
        XCTAssertEqual(try OKXWebSocketParser.quotes(mark, contracts: lookup, receivedAt: now).first?.contract.id, Contract.btc.id)
    }

    func testRejectsWrongChannelAndSurfacesSubscriptionFailure() {
        let lookup = [Contract.btc.instrumentID: Contract.btc]
        let wrong = Data(#"{"arg":{"channel":"tickers"},"data":[{"instId":"BTC-USDT-SWAP","last":"1","ts":"1800000000000"}]}"#.utf8)
        XCTAssertThrowsError(try OKXWebSocketParser.quotes(wrong, contracts: lookup, receivedAt: Date()))
        let rejected = Data(#"{"event":"error","arg":{"channel":"mark-price","instId":"BTC-USDT-SWAP"},"msg":"bad subscription"}"#.utf8)
        let events = try? OKXWebSocketParser.events(rejected, contracts: lookup, receivedAt: Date())
        XCTAssertEqual(events, [.subscriptionFailed(.btc, "bad subscription")])

        let connectionFailure = Data(#"{"event":"error","msg":"connection failure"}"#.utf8)
        XCTAssertThrowsError(try OKXWebSocketParser.events(connectionFailure, contracts: lookup, receivedAt: Date()))
    }
}
