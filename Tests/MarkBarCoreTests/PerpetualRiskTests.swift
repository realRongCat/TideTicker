import XCTest
@testable import MarkBarCore

final class PerpetualRiskTests: XCTestCase {
    func testBuildsSameExchangeUSDTReferenceAndComputesPremium() {
        let spot = ReferenceSpot.contract(for: .btc)
        XCTAssertEqual(spot?.instrumentID, "BTC-USDT")
        XCTAssertEqual(spot?.exchange, .okx)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let details = MarketDetails(lastPrice: 101, change24hPercent: 2,
                                    fundingRate: Decimal(string: "0.0001"),
                                    nextFundingTime: now.addingTimeInterval(3600), updatedAt: now)
        let mark = MarkQuote(contract: .btc, price: 101, dataTime: now, receivedAt: now)
        let quote = MarkQuote(contract: spot!, price: 100,
                              dataTime: now.addingTimeInterval(-10), receivedAt: now)
        let risk = PerpetualRiskSnapshot(markQuote: mark, details: details, referenceSpot: quote,
                                         now: now, staleAfter: 20)
        XCTAssertEqual(risk.premiumPercent, 1)
        XCTAssertEqual(risk.fundingRate, Decimal(string: "0.0001"))
    }

    func testInversePerpetualHasNoReferenceSpot() {
        let inverse = Contract(exchange: .okx, instrumentID: "BTC-USD-SWAP", symbol: "BTC",
                               marketKind: .inversePerpetual, quoteCurrency: "USD",
                               settlementCurrency: "BTC", priceKind: .mark)
        XCTAssertNil(ReferenceSpot.contract(for: inverse))
    }

    func testPremiumIsUnavailableWhenMarkOrReferenceSpotIsStale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let spotContract = ReferenceSpot.contract(for: .btc)!
        let details = MarketDetails(lastPrice: nil, change24hPercent: nil,
                                    fundingRate: nil, nextFundingTime: nil, updatedAt: now)
        func quote(_ contract: Contract, _ price: Decimal, age: TimeInterval) -> MarkQuote {
            MarkQuote(contract: contract, price: price,
                      dataTime: now.addingTimeInterval(-age), receivedAt: now)
        }

        let staleMark = PerpetualRiskSnapshot(
            markQuote: quote(.btc, 101, age: 21), details: details,
            referenceSpot: quote(spotContract, 100, age: 0), now: now, staleAfter: 20
        )
        let staleSpot = PerpetualRiskSnapshot(
            markQuote: quote(.btc, 101, age: 0), details: details,
            referenceSpot: quote(spotContract, 100, age: 21), now: now, staleAfter: 20
        )

        XCTAssertNil(staleMark.premiumPercent)
        XCTAssertNil(staleSpot.premiumPercent)
    }
}
