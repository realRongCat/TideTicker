import Foundation
import XCTest
@testable import MarkBarCore

final class KindleDisplaySnapshotTests: XCTestCase {
    func testSnapshotPreservesQuoteSemanticsAndSupplementalData() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let spot = Contract(exchange: .okx, instrumentID: "BTC-USDT", symbol: "BTC",
                            marketKind: .spot, priceKind: .last)
        let quote = MarkQuote(contract: .btc, price: 80_123.45,
                              dataTime: now.addingTimeInterval(-1), receivedAt: now)
        let state = MainQuoteState(contract: .btc, entry: QuoteEntry(quote: quote), isStale: false,
                                   continuityEpoch: 3, continuity: .continuous(since: now),
                                   route: .webSocket)
        let snapshot = MainQuoteSnapshot(revision: 9, phase: .streaming,
                                         entries: [Contract.btc.id: state], observedAt: now)
        let detail = MarketDetails(lastPrice: 80_100, change24hPercent: 1.25,
                                   fundingRate: Decimal(string: "0.0001"),
                                   nextFundingTime: now.addingTimeInterval(3_661), updatedAt: now)
        let spotQuote = MarkQuote(contract: spot, price: 80_000,
                                  dataTime: now, receivedAt: now)
        let preferences = TidePreferences(watchlist: [.btc], showsMarketDetails: true)

        let result = KindleDisplaySnapshotFactory.make(
            preferences: preferences, quoteSnapshot: snapshot,
            details: [.btc: detail], referenceSpots: [.btc: spotQuote], now: now
        )

        XCTAssertEqual(result.schemaVersion, 1)
        XCTAssertEqual(result.revision, 9)
        XCTAssertEqual(result.sessionPhase, "WebSocket 连续行情")
        XCTAssertEqual(result.quotes.count, 1)
        XCTAssertEqual(result.quotes[0].priceKind, "标记价")
        XCTAssertEqual(result.quotes[0].route, "WebSocket")
        XCTAssertEqual(result.quotes[0].supplement?.change24h, "+1.25%")
        XCTAssertEqual(result.quotes[0].supplement?.fundingRate, "0.01%")
        XCTAssertEqual(result.quotes[0].supplement?.fundingCountdown, "01:01:01")
        XCTAssertEqual(result.quotes[0].supplement?.premium, "+0.1543%")
        XCTAssertNoThrow(try JSONEncoder().encode(result))
    }

    func testCriticalSignatureIgnoresPriceTicksButTracksCoverageAndPendingAlerts() {
        let base = KindleDisplayQuote(contractID: "btc", instrumentID: "BTC-USDT-SWAP",
            title: "BTC/USDT · USDT 永续", marketKind: "USDT 永续", priceKind: "标记价",
            price: "80,000.00", quoteCurrency: "USDT", dataTime: nil, receivedAt: nil,
            isStale: false, possiblyMissed: false, continuity: "连续行情",
            route: "WebSocket", hasError: false, supplement: nil)
        let changedPrice = KindleDisplayQuote(contractID: "btc", instrumentID: "BTC-USDT-SWAP",
            title: base.title, marketKind: base.marketKind, priceKind: base.priceKind,
            price: "81,000.00", quoteCurrency: base.quoteCurrency, dataTime: nil, receivedAt: nil,
            isStale: false, possiblyMissed: false, continuity: "连续行情",
            route: "WebSocket", hasError: false, supplement: nil)
        let stale = KindleDisplayQuote(contractID: "btc", instrumentID: "BTC-USDT-SWAP",
            title: base.title, marketKind: base.marketKind, priceKind: base.priceKind,
            price: base.price, quoteCurrency: base.quoteCurrency, dataTime: nil, receivedAt: nil,
            isStale: true, possiblyMissed: false, continuity: "连续行情",
            route: "WebSocket", hasError: false, supplement: nil)
        let first = KindleDisplaySnapshot(revision: 1, generatedAt: .distantPast,
            exchange: "OKX", sessionPhase: "WebSocket 连续行情", supplementalEnabled: false,
            quotes: [base], pendingAlert: nil)
        let priceOnly = KindleDisplaySnapshot(revision: 2, generatedAt: Date(),
            exchange: "OKX", sessionPhase: "WebSocket 连续行情", supplementalEnabled: false,
            quotes: [changedPrice], pendingAlert: nil)
        let staleState = KindleDisplaySnapshot(revision: 2, generatedAt: Date(),
            exchange: "OKX", sessionPhase: "WebSocket 连续行情", supplementalEnabled: false,
            quotes: [stale], pendingAlert: nil)

        XCTAssertEqual(first.criticalSignature, priceOnly.criticalSignature)
        XCTAssertNotEqual(first.criticalSignature, staleState.criticalSignature)

        let ruleID = UUID()
        let pending = KindleDisplayPendingAlert(
            ruleID: ruleID, title: "OKX · BTC-USDT-SWAP",
            condition: "标记价 上穿 80,000", latestPrice: "80,001.00",
            latestTriggeredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let updatedPending = KindleDisplayPendingAlert(
            ruleID: ruleID, title: pending.title, condition: pending.condition,
            latestPrice: "80,100.00",
            latestTriggeredAt: Date(timeIntervalSince1970: 1_800_000_060)
        )
        let pendingState = KindleDisplaySnapshot(
            revision: 2, generatedAt: Date(), exchange: "OKX",
            sessionPhase: "WebSocket 连续行情", supplementalEnabled: false,
            quotes: [base], pendingAlert: pending
        )
        let updatedPendingState = KindleDisplaySnapshot(
            revision: 2, generatedAt: Date(), exchange: "OKX",
            sessionPhase: "WebSocket 连续行情", supplementalEnabled: false,
            quotes: [base], pendingAlert: updatedPending
        )

        XCTAssertNotEqual(first.criticalSignature, pendingState.criticalSignature)
        XCTAssertNotEqual(pendingState.criticalSignature, updatedPendingState.criticalSignature)
    }

    func testCriticalSignatureTracksContinuityReason() {
        let startup = KindleDisplayQuote(
            contractID: "btc", instrumentID: "BTC-USDT-SWAP",
            title: "BTC/USDT · USDT 永续", marketKind: "USDT 永续", priceKind: "标记价",
            price: "80,000.00", quoteCurrency: "USDT", dataTime: nil, receivedAt: nil,
            isStale: false, possiblyMissed: true, continuity: "启动后等待连续行情",
            route: "REST", hasError: false, supplement: nil
        )
        let sampling = KindleDisplayQuote(
            contractID: startup.contractID, instrumentID: startup.instrumentID,
            title: startup.title, marketKind: startup.marketKind, priceKind: startup.priceKind,
            price: startup.price, quoteCurrency: startup.quoteCurrency, dataTime: nil, receivedAt: nil,
            isStale: false, possiblyMissed: true, continuity: "REST 采样可能漏报",
            route: startup.route, hasError: false, supplement: nil
        )
        let first = KindleDisplaySnapshot(
            revision: 1, generatedAt: Date(), exchange: "OKX", sessionPhase: "REST 采样",
            supplementalEnabled: false, quotes: [startup], pendingAlert: nil
        )
        let second = KindleDisplaySnapshot(
            revision: 1, generatedAt: Date(), exchange: "OKX", sessionPhase: "REST 采样",
            supplementalEnabled: false, quotes: [sampling], pendingAlert: nil
        )

        XCTAssertNotEqual(first.criticalSignature, second.criticalSignature)
    }

    func testDisabledSupplementalDataIsOmittedAndMissingQuoteIsMarkedAsGap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = KindleDisplaySnapshotFactory.make(
            preferences: TidePreferences(watchlist: [.btc], showsMarketDetails: false),
            quoteSnapshot: MainQuoteSnapshot(revision: 0, phase: .connecting,
                                             entries: [:], observedAt: now),
            details: [:], referenceSpots: [:], now: now
        )

        XCTAssertEqual(result.quotes[0].price, "--")
        XCTAssertTrue(result.quotes[0].possiblyMissed)
        XCTAssertNil(result.quotes[0].supplement)
    }
}
