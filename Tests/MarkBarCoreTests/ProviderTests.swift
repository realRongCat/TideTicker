import Foundation
import XCTest
@testable import MarkBarCore

final class ProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private let binanceBTC = Contract(exchange: .binance, instrumentID: "BTCUSDT", symbol: "BTC")
    private let bybitBTC = Contract(exchange: .bybit, instrumentID: "BTCUSDT", symbol: "BTC")
    private let okxSpotBTC = Contract(exchange: .okx, instrumentID: "BTC-USDT", symbol: "BTC",
                                      marketKind: .spot, priceKind: .last)
    private let binanceSpotBTC = Contract(exchange: .binance, instrumentID: "BTCUSDT", symbol: "BTC",
                                          marketKind: .spot, priceKind: .last)
    private let binanceInverseBTC = Contract(exchange: .binance, instrumentID: "BTCUSD_PERP", symbol: "BTC",
                                             marketKind: .inversePerpetual, quoteCurrency: "USD",
                                             settlementCurrency: "BTC")
    private let bybitSpotBTC = Contract(exchange: .bybit, instrumentID: "BTCUSDT", symbol: "BTC",
                                        marketKind: .spot, priceKind: .last)
    private let bybitInverseBTC = Contract(exchange: .bybit, instrumentID: "BTCUSD", symbol: "BTC",
                                           marketKind: .inversePerpetual, quoteCurrency: "USD",
                                           settlementCurrency: "BTC")

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func okxInstrument(_ changes: [String: String] = [:]) -> [String: String] {
        ["instType": "SWAP", "instId": "BTC-USDT-SWAP", "ctType": "linear", "settleCcy": "USDT",
         "ctValCcy": "BTC", "state": "live", "ruleType": "normal"].merging(changes) { _, new in new }
    }
    private func binanceInstrument(_ changes: [String: String] = [:]) -> [String: String] {
        ["symbol": "BTCUSDT", "contractType": "PERPETUAL", "status": "TRADING", "baseAsset": "BTC",
         "quoteAsset": "USDT", "marginAsset": "USDT"].merging(changes) { _, new in new }
    }
    private func bybitInstrument(_ changes: [String: Any] = [:]) -> [String: Any] {
        ["symbol": "BTCUSDT", "contractType": "LinearPerpetual", "status": "Trading", "baseCoin": "BTC",
         "quoteCoin": "USDT", "settleCoin": "USDT", "isPreListing": false].merging(changes) { _, new in new }
    }
    private func bybitResponse(_ rows: [[String: Any]], category: String = "linear", time: Int64 = 1_792_000_000_000) -> Data {
        json(["retCode": 0, "result": ["category": category, "list": rows, "nextPageCursor": "next-page"], "time": time])
    }
    private func premium(_ changes: [String: Any] = [:]) -> Data {
        json(["symbol": "BTCUSDT", "markPrice": "101.2", "indexPrice": "999.0", "lastFundingRate": "-0.0001",
              "nextFundingTime": Int64(1_792_028_800_000), "time": Int64(1_792_000_000_000)].merging(changes) { _, new in new })
    }
    private func bybitTicker(_ changes: [String: Any] = [:]) -> [String: Any] {
        ["symbol": "BTCUSDT", "markPrice": "101.2", "lastPrice": "102.4", "price24hPcnt": "0.012",
         "fundingRate": "-0.0001", "nextFundingTime": "1792028800000"].merging(changes) { _, new in new }
    }

    private func binanceTicker(_ changes: [String: Any] = [:]) -> Data {
        json(["symbol": "BTCUSDT", "lastPrice": "102.4", "priceChangePercent": "1.2",
              "closeTime": Int64(1_792_000_000_000)].merging(changes) { _, new in new })
    }

    func testContractIdentityUsesVenueMarketAndInstrumentNotDisplayName() throws {
        let alias = Contract(exchange: .binance, instrumentID: "BTCUSDT", symbol: "Bitcoin")
        XCTAssertEqual(alias, binanceBTC)
        XCTAssertEqual(Set([alias, binanceBTC]).count, 1)
        XCTAssertNotEqual(binanceBTC.id, bybitBTC.id)
        XCTAssertNotEqual(Contract.btc.id, binanceBTC.id)
        XCTAssertTrue(binanceBTC.id.contains("USDT:perpetual:mark:"))
        XCTAssertEqual(try JSONDecoder().decode(Contract.self, from: JSONEncoder().encode(binanceBTC)), binanceBTC)
    }

    func testMarketUsageDescriptionsKeepPriceAndSettlementSemanticsExplicit() {
        XCTAssertEqual(MarketKind.spot.usageDescription, "看实际成交市场，主报价为最新成交价。")
        XCTAssertTrue(MarketKind.linearPerpetual.usageDescription.contains("USDT 结算"))
        XCTAssertTrue(MarketKind.linearPerpetual.usageDescription.contains("标记价"))
        XCTAssertTrue(MarketKind.inversePerpetual.usageDescription.contains("USD 报价"))
        XCTAssertTrue(MarketKind.inversePerpetual.usageDescription.contains("标的币结算"))
        XCTAssertTrue(MarketKind.inversePerpetual.usageDescription.contains("标记价"))
    }

    func testMarketIdentitySeparatesSpotLinearAndInverseWhileLegacyJSONKeepsItsID() throws {
        XCTAssertNotEqual(okxSpotBTC.id, Contract.btc.id)
        XCTAssertNotEqual(binanceSpotBTC.id, binanceBTC.id)
        XCTAssertNotEqual(binanceInverseBTC.id, binanceBTC.id)
        XCTAssertEqual(okxSpotBTC.priceTitle, "最新成交价")
        XCTAssertEqual(binanceInverseBTC.displayTitle, "BTC/USD · 币本位永续")

        let legacy = Data(#"{"exchange":"okx","instrumentID":"BTC-USDT-SWAP","symbol":"BTC"}"#.utf8)
        let decoded = try JSONDecoder().decode(Contract.self, from: legacy)
        XCTAssertEqual(decoded, .btc)
        XCTAssertEqual(decoded.id, "okx:USDT:perpetual:mark:BTC-USDT-SWAP")
        XCTAssertEqual(decoded.marketKind, .linearPerpetual)
    }

    func testOKXCatalogParsesUSDTSpotAndBothPerpetualKinds() throws {
        let spot = json(["code": "0", "data": [["instType": "SPOT", "instId": "BTC-USDT",
            "baseCcy": "BTC", "quoteCcy": "USDT", "state": "live", "ruleType": "normal"]]])
        XCTAssertEqual(try InstrumentCatalogParser.okxSpot(spot), [okxSpotBTC])

        let inverse = okxInstrument(["instId": "BTC-USD-SWAP", "ctType": "inverse",
                                     "settleCcy": "BTC", "ctValCcy": "USD"])
        let parsed = try InstrumentCatalogParser.okxPerpetuals(json(["code": "0", "data": [okxInstrument(), inverse]]))
        XCTAssertEqual(parsed.map(\.marketKind), [.linearPerpetual, .inversePerpetual])
        XCTAssertEqual(parsed.last?.quoteCurrency, "USD")
        XCTAssertEqual(parsed.last?.settlementCurrency, "BTC")
    }

    func testBinanceCatalogParsesUSDTSpotAndCoinMarginedPerpetual() throws {
        let spot = json(["symbols": [["symbol": "BTCUSDT", "status": "TRADING", "baseAsset": "BTC",
                                      "quoteAsset": "USDT", "isSpotTradingAllowed": true]]])
        XCTAssertEqual(try InstrumentCatalogParser.binanceSpot(spot), [binanceSpotBTC])
        let inverse = json(["symbols": [["symbol": "BTCUSD_PERP", "contractType": "PERPETUAL",
            "status": "TRADING", "baseAsset": "BTC", "quoteAsset": "USD", "marginAsset": "BTC"]]])
        XCTAssertEqual(try InstrumentCatalogParser.binanceInverse(inverse), [binanceInverseBTC])
    }

    func testBybitCatalogParsesSpotAndInversePerpetualByCategory() throws {
        let spot = bybitResponse([["symbol": "BTCUSDT", "status": "Trading", "baseCoin": "BTC",
                                   "quoteCoin": "USDT"]], category: "spot")
        XCTAssertEqual(try InstrumentCatalogParser.bybitPage(spot, marketKind: .spot).contracts, [bybitSpotBTC])
        let inverse = bybitResponse([["symbol": "BTCUSD", "contractType": "InversePerpetual",
            "status": "Trading", "baseCoin": "BTC", "quoteCoin": "USD", "settleCoin": "BTC",
            "isPreListing": false]], category: "inverse")
        XCTAssertEqual(try InstrumentCatalogParser.bybitPage(inverse, marketKind: .inversePerpetual).contracts,
                       [bybitInverseBTC])
    }

    func testSpotQuotesUseLastPriceAndNeverExposeFunding() throws {
        let okx = json(["code": "0", "data": [["instType": "SPOT", "instId": "BTC-USDT",
            "last": "102.4", "open24h": "100", "ts": "1792000000000"]]])
        XCTAssertEqual(try OKXSpotResponseParser.quote(okx, contract: okxSpotBTC, receivedAt: now).price,
                       Decimal(string: "102.4"))
        let okxDetails = try OKXSupplementParser.spot(ticker: okx, contract: okxSpotBTC, now: now)
        XCTAssertEqual(okxDetails.change24hPercent, Decimal(string: "2.4"))
        XCTAssertNil(okxDetails.fundingRate)

        XCTAssertEqual(try BinanceResponseParser.spot(binanceTicker(), contract: binanceSpotBTC,
                                                       receivedAt: now).price, Decimal(string: "102.4"))
        XCTAssertNil(try BinanceResponseParser.spotDetails(binanceTicker(), contract: binanceSpotBTC,
                                                            now: now).fundingRate)
        XCTAssertThrowsError(try BinanceResponseParser.spot(binanceTicker(), contract: binanceBTC,
                                                             receivedAt: now))

        let spotTicker = bybitResponse([["symbol": "BTCUSDT", "lastPrice": "102.4",
                                         "price24hPcnt": "0.012"]], category: "spot")
        XCTAssertEqual(try BybitResponseParser.quote(spotTicker, contract: bybitSpotBTC,
                                                     receivedAt: now).price, Decimal(string: "102.4"))
        XCTAssertNil(try BybitResponseParser.details(spotTicker, contract: bybitSpotBTC, now: now).fundingRate)
    }

    func testInversePerpetualQuotesKeepMarkPriceAndUSDPricing() throws {
        let inversePremium = premium(["symbol": "BTCUSD_PERP"])
        let binanceQuote = try BinanceResponseParser.mark(inversePremium, contract: binanceInverseBTC,
                                                          receivedAt: now)
        XCTAssertEqual(binanceQuote.price, Decimal(string: "101.2"))
        XCTAssertEqual(binanceQuote.contract.quoteCurrency, "USD")

        let inverseTicker = bybitResponse([["symbol": "BTCUSD", "markPrice": "101.2",
            "lastPrice": "999", "price24hPcnt": "0.012", "fundingRate": "0.0001"]], category: "inverse")
        XCTAssertEqual(try BybitResponseParser.quote(inverseTicker, contract: bybitInverseBTC,
                                                     receivedAt: now).price, Decimal(string: "101.2"))
    }

    func testOKXCatalogExcludesInactiveInverseAndPremarketContracts() throws {
        let rows = [okxInstrument(), okxInstrument(["state": "preopen"]), okxInstrument(["ctType": "inverse"]),
                    okxInstrument(["ruleType": "pre_market"]), okxInstrument(["ruleType": "rebase_contract"]),
                    okxInstrument(["settleCcy": "USDC"]), okxInstrument(["instType": "FUTURES"])]
        XCTAssertEqual(try InstrumentCatalogParser.okx(json(["code": "0", "data": rows])), [.btc])
    }

    func testBinanceCatalogExcludesDeliveryInactiveAndNonUSDTContracts() throws {
        let rows = [binanceInstrument(), binanceInstrument(["contractType": "CURRENT_QUARTER"]),
                    binanceInstrument(["status": "PRE_TRADING"]), binanceInstrument(["status": "SETTLING"]),
                    binanceInstrument(["marginAsset": "BTC"]), binanceInstrument(["quoteAsset": "USDC"])]
        XCTAssertEqual(try InstrumentCatalogParser.binance(json(["symbols": rows])), [binanceBTC])
    }

    func testCatalogRejectsUnknownMarketMetadataAndPreservesNativeAssetNames() throws {
        var unknown = okxInstrument()
        unknown.removeValue(forKey: "ruleType")
        XCTAssertThrowsError(try InstrumentCatalogParser.okx(json(["code": "0", "data": [unknown]])))
        XCTAssertThrowsError(try InstrumentCatalogParser.binance(json(["symbols": []])))
        let row = binanceInstrument(["symbol": "示例USDT", "baseAsset": "示例"])
        XCTAssertEqual(try InstrumentCatalogParser.binance(json(["symbols": [row]])).first?.symbol, "示例")
    }

    func testBybitCatalogFiltersPremarketAndKeepsPaginationCursor() throws {
        let rows = [bybitInstrument(), bybitInstrument(["isPreListing": true]),
                    bybitInstrument(["status": "PendingOpen"]), bybitInstrument(["contractType": "LinearFutures"]),
                    bybitInstrument(["quoteCoin": "USDC"]), bybitInstrument(["settleCoin": "BTC"])]
        let page = try InstrumentCatalogParser.bybitPage(bybitResponse(rows))
        XCTAssertEqual(page.contracts, [bybitBTC])
        XCTAssertEqual(page.nextCursor, "next-page")
        XCTAssertThrowsError(try InstrumentCatalogParser.bybitPage(bybitResponse(rows, category: "spot")))
    }

    func testBinanceMarkUsesMarkFieldAndRejectsWrongSourceAndOldTime() throws {
        let quote = try BinanceResponseParser.mark(premium(), contract: binanceBTC, receivedAt: now)
        XCTAssertEqual(quote.price, Decimal(string: "101.2"))
        XCTAssertThrowsError(try BinanceResponseParser.mark(premium(), contract: bybitBTC, receivedAt: now))
        XCTAssertThrowsError(try BinanceResponseParser.mark(premium(["symbol": "ETHUSDT"]), contract: binanceBTC, receivedAt: now))
        for badTime: Int64 in [1_791_999_939_000, 1_792_000_031_000, 1_792_000_000] {
            XCTAssertThrowsError(try BinanceResponseParser.mark(premium(["time": badTime]), contract: binanceBTC, receivedAt: now))
        }
        for price in ["0", "-1", "NaN", "101.2\n"] {
            XCTAssertThrowsError(try BinanceResponseParser.mark(premium(["markPrice": price]), contract: binanceBTC, receivedAt: now))
        }
    }

    func testBybitUsesServerTimestampAndNeverSubstitutesLastPrice() throws {
        let quote = try BybitResponseParser.mark(bybitResponse([bybitTicker()]), contract: bybitBTC, receivedAt: now)
        XCTAssertEqual(quote.price, Decimal(string: "101.2"))
        XCTAssertEqual(quote.dataTime, now)
        XCTAssertTrue(Exchange.bybit.markTimeDescription.contains("服务器响应"))
        XCTAssertThrowsError(try BybitResponseParser.mark(bybitResponse([bybitTicker(["markPrice": ""])]), contract: bybitBTC, receivedAt: now))
        XCTAssertThrowsError(try BybitResponseParser.mark(bybitResponse([bybitTicker()]), contract: binanceBTC, receivedAt: now))
        XCTAssertThrowsError(try BybitResponseParser.mark(bybitResponse([bybitTicker()], time: 1_791_999_939_000), contract: bybitBTC, receivedAt: now))
        XCTAssertThrowsError(try BybitResponseParser.mark(bybitResponse([bybitTicker()], category: "inverse"), contract: bybitBTC, receivedAt: now))
    }

    func testSupplementPercentageAndFundingUnitsStayDistinct() throws {
        let bybit = try BybitResponseParser.details(bybitResponse([bybitTicker()]), contract: bybitBTC, now: now)
        XCTAssertEqual(bybit.change24hPercent, Decimal(string: "1.2"))
        XCTAssertEqual(bybit.fundingRate, Decimal(string: "-0.0001"))
        let binance = try BinanceResponseParser.details(ticker: json(["symbol": "BTCUSDT", "lastPrice": "102.4", "priceChangePercent": "1.2"]), funding: premium(), contract: binanceBTC, now: now)
        XCTAssertEqual(binance.change24hPercent, Decimal(string: "1.2"))
        XCTAssertEqual(binance.fundingRate, Decimal(string: "-0.0001"))
        XCTAssertEqual(binance.nextFundingTime, bybit.nextFundingTime)
    }

    func testOKXDetailsMapsCurrentSettlementRatherThanFollowingCycle() throws {
        let ticker = json(["code": "0", "data": [["instType": "SWAP", "instId": "BTC-USDT-SWAP", "last": "101.2", "open24h": "100", "ts": "1792000000000"]]])
        let funding = json(["code": "0", "data": [["instType": "SWAP", "instId": "BTC-USDT-SWAP", "fundingRate": "0.0001", "fundingTime": "1792028800000", "nextFundingTime": "1792057600000", "ts": "1792000000000"]]])
        let details = try OKXSupplementParser.details(ticker: ticker, funding: funding, contract: .btc, now: now)
        XCTAssertEqual(details.change24hPercent, Decimal(string: "1.2"))
        XCTAssertEqual(details.nextFundingTime, Date(timeIntervalSince1970: 1_792_028_800))
        XCTAssertThrowsError(try OKXSupplementParser.details(ticker: ticker, funding: funding, contract: .eth, now: now))
    }

    func testQuoteBookSeparatesVenuesAndHonorsConfiguredStaleThreshold() {
        var book = QuoteBook()
        book.apply(MarkQuote(contract: binanceBTC, price: 100, dataTime: now, receivedAt: now), now: now)
        book.apply(MarkQuote(contract: bybitBTC, price: 200, dataTime: now, receivedAt: now), now: now)
        book.recordFailure(binanceBTC, message: "HTTP 451")
        XCTAssertEqual(book.entry(for: bybitBTC).quote?.price, 200)
        XCTAssertNil(book.entry(for: bybitBTC).lastError)
        XCTAssertTrue(book.entry(for: bybitBTC).isStale(at: now.addingTimeInterval(21)))
        XCTAssertFalse(book.entry(for: bybitBTC).isStale(at: now.addingTimeInterval(21), threshold: 30))
        XCTAssertTrue(book.entry(for: bybitBTC).isStale(at: now.addingTimeInterval(31), threshold: 30))
    }
}
