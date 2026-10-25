import Foundation

public struct PerpetualRiskSnapshot: Sendable, Equatable {
    public let fundingRate: Decimal?
    public let nextFundingTime: Date?
    public let referenceSpotPrice: Decimal?
    public let premiumPercent: Decimal?
    public let updatedAt: Date

    public init(markQuote: MarkQuote?, details: MarketDetails, referenceSpot: MarkQuote?,
                now: Date, staleAfter: TimeInterval) {
        fundingRate = details.fundingRate
        nextFundingTime = details.nextFundingTime
        referenceSpotPrice = referenceSpot?.price
        updatedAt = max(details.updatedAt, markQuote?.receivedAt ?? .distantPast,
                        referenceSpot?.receivedAt ?? .distantPast)
        if let markQuote, let referenceSpot,
           !QuoteEntry(quote: markQuote).isStale(at: now, threshold: staleAfter),
           !QuoteEntry(quote: referenceSpot).isStale(at: now, threshold: staleAfter),
           markQuote.price > 0, referenceSpot.price > 0 {
            premiumPercent = (markQuote.price - referenceSpot.price) / referenceSpot.price * 100
        } else {
            premiumPercent = nil
        }
    }
}

public enum ReferenceSpot {
    /// Premium/discount is only defined when the same exchange exposes the same
    /// symbol in the same quote currency. The current product supports USDT
    /// reference spots; inverse USD perpetuals deliberately return nil.
    public static func contract(for perpetual: Contract) -> Contract? {
        guard perpetual.marketKind == .linearPerpetual,
              perpetual.quoteCurrency == "USDT" else { return nil }
        let instrumentID: String
        switch perpetual.exchange {
        case .okx: instrumentID = "\(perpetual.symbol)-USDT"
        case .binance, .bybit: instrumentID = "\(perpetual.symbol)USDT"
        }
        return Contract(exchange: perpetual.exchange, instrumentID: instrumentID,
                        symbol: perpetual.symbol, marketKind: .spot,
                        quoteCurrency: "USDT", settlementCurrency: "USDT",
                        priceKind: .last)
    }
}
