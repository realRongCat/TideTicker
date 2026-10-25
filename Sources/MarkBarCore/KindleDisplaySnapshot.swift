import Foundation

public struct KindleDisplaySupplement: Codable, Equatable, Sendable {
    public let change24h: String
    public let fundingRate: String?
    public let fundingCountdown: String?
    public let premium: String?
    public let isStale: Bool

    public init(change24h: String, fundingRate: String?, fundingCountdown: String?,
                premium: String?, isStale: Bool) {
        self.change24h = change24h
        self.fundingRate = fundingRate
        self.fundingCountdown = fundingCountdown
        self.premium = premium
        self.isStale = isStale
    }
}

public struct KindleDisplayQuote: Codable, Equatable, Sendable {
    public let contractID: String
    public let instrumentID: String
    public let title: String
    public let marketKind: String
    public let priceKind: String
    public let price: String
    public let quoteCurrency: String
    public let dataTime: Date?
    public let receivedAt: Date?
    public let isStale: Bool
    public let possiblyMissed: Bool
    public let continuity: String
    public let route: String?
    public let hasError: Bool
    public let supplement: KindleDisplaySupplement?

    public init(contractID: String, instrumentID: String, title: String,
                marketKind: String, priceKind: String, price: String,
                quoteCurrency: String, dataTime: Date?, receivedAt: Date?,
                isStale: Bool, possiblyMissed: Bool, continuity: String,
                route: String?, hasError: Bool, supplement: KindleDisplaySupplement?) {
        self.contractID = contractID
        self.instrumentID = instrumentID
        self.title = title
        self.marketKind = marketKind
        self.priceKind = priceKind
        self.price = price
        self.quoteCurrency = quoteCurrency
        self.dataTime = dataTime
        self.receivedAt = receivedAt
        self.isStale = isStale
        self.possiblyMissed = possiblyMissed
        self.continuity = continuity
        self.route = route
        self.hasError = hasError
        self.supplement = supplement
    }
}

public struct KindleDisplayPendingAlert: Codable, Equatable, Sendable {
    public let ruleID: UUID
    public let title: String
    public let condition: String
    public let latestPrice: String
    public let latestTriggeredAt: Date

    public init(ruleID: UUID, title: String, condition: String,
                latestPrice: String, latestTriggeredAt: Date) {
        self.ruleID = ruleID
        self.title = title
        self.condition = condition
        self.latestPrice = latestPrice
        self.latestTriggeredAt = latestTriggeredAt
    }
}

public struct KindleDisplaySnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: UInt64
    public let generatedAt: Date
    public let exchange: String
    public let sessionPhase: String
    public let supplementalEnabled: Bool
    public let quotes: [KindleDisplayQuote]
    public let pendingAlert: KindleDisplayPendingAlert?

    public init(schemaVersion: Int = 1, revision: UInt64, generatedAt: Date,
                exchange: String, sessionPhase: String, supplementalEnabled: Bool,
                quotes: [KindleDisplayQuote], pendingAlert: KindleDisplayPendingAlert?) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.generatedAt = generatedAt
        self.exchange = exchange
        self.sessionPhase = sessionPhase
        self.supplementalEnabled = supplementalEnabled
        self.quotes = quotes
        self.pendingAlert = pendingAlert
    }

    /// Status changes bypass the normal e-ink display cadence. Price ticks and
    /// countdown changes are intentionally excluded so they remain throttled.
    public var criticalSignature: String {
        let quoteState = quotes.map {
            "\($0.contractID):\($0.price == "--" ? 0 : 1):\($0.isStale ? 1 : 0):\($0.possiblyMissed ? 1 : 0):\($0.continuity):\($0.route ?? "-"):\($0.hasError ? 1 : 0):\($0.supplement?.isStale == true ? 1 : 0)"
        }.joined(separator: "|")
        let alertState = pendingAlert.map {
            "\($0.ruleID.uuidString):\($0.title):\($0.condition):\($0.latestPrice):\($0.latestTriggeredAt.timeIntervalSince1970)"
        } ?? "-"
        return "\(sessionPhase)|\(supplementalEnabled ? 1 : 0)|\(quoteState)|\(alertState)"
    }
}

public enum KindleDisplaySnapshotFactory {
    public static func make(preferences: TidePreferences, quoteSnapshot: MainQuoteSnapshot,
                            details: [Contract: MarketDetails], referenceSpots: [Contract: MarkQuote],
                            now: Date = Date()) -> KindleDisplaySnapshot {
        let quotes = preferences.watchlist.map { contract in
            let state = quoteSnapshot.state(for: contract)
            let quote = state?.entry.quote
            return KindleDisplayQuote(
                contractID: contract.id,
                instrumentID: contract.instrumentID,
                title: contract.displayTitle,
                marketKind: contract.marketKind.title,
                priceKind: contract.priceKind.title,
                price: quote.map { PriceFormatting.compact($0.price) } ?? "--",
                quoteCurrency: contract.quoteCurrency,
                dataTime: quote?.dataTime,
                receivedAt: quote?.receivedAt,
                isStale: state?.isStale ?? false,
                possiblyMissed: state?.possiblyMissed ?? true,
                continuity: state?.continuity.description ?? "等待连续行情",
                route: state?.route?.title,
                hasError: state?.entry.lastError != nil,
                supplement: supplement(for: contract, preferences: preferences,
                                       quote: quote, details: details[contract],
                                       referenceSpot: referenceSpots[contract], now: now)
            )
        }
        let latestPending = preferences.pendingAlerts.max { $0.latestTriggeredAt < $1.latestTriggeredAt }
        let pendingAlert = latestPending.map {
            KindleDisplayPendingAlert(
                ruleID: $0.ruleID,
                title: "\($0.contract.exchange.title) · \($0.contract.instrumentID)",
                condition: "\($0.contract.priceTitle) \($0.direction.title) \(PriceFormatting.exact($0.threshold))",
                latestPrice: PriceFormatting.compact($0.latestPrice),
                latestTriggeredAt: $0.latestTriggeredAt
            )
        }
        return KindleDisplaySnapshot(
            revision: quoteSnapshot.revision,
            generatedAt: now,
            exchange: preferences.exchange.title,
            sessionPhase: quoteSnapshot.phase.title,
            supplementalEnabled: preferences.showsMarketDetails,
            quotes: quotes,
            pendingAlert: pendingAlert
        )
    }

    private static func supplement(for contract: Contract, preferences: TidePreferences,
                                   quote: MarkQuote?, details: MarketDetails?,
                                   referenceSpot: MarkQuote?, now: Date) -> KindleDisplaySupplement? {
        guard preferences.showsMarketDetails else { return nil }
        guard let details else {
            return KindleDisplaySupplement(
                change24h: "--",
                fundingRate: contract.marketKind.isPerpetual ? "--" : nil,
                fundingCountdown: contract.marketKind.isPerpetual ? "--" : nil,
                premium: contract.marketKind.isPerpetual
                    ? (contract.marketKind == .inversePerpetual ? "不可用" : "--") : nil,
                isStale: false
            )
        }
        let change = details.change24hPercent.map { PriceFormatting.percent($0, signed: true) } ?? "--"
        let detailsStale = now.timeIntervalSince(details.updatedAt) > 120
        guard contract.marketKind.isPerpetual else {
            return KindleDisplaySupplement(change24h: change, fundingRate: nil,
                                           fundingCountdown: nil, premium: nil,
                                           isStale: detailsStale)
        }
        let risk = PerpetualRiskSnapshot(markQuote: quote, details: details,
                                         referenceSpot: referenceSpot, now: now,
                                         staleAfter: preferences.staleAfter)
        return KindleDisplaySupplement(
            change24h: change,
            fundingRate: details.fundingRate.map { PriceFormatting.percent($0 * 100) } ?? "--",
            fundingCountdown: details.nextFundingTime.map { countdown(to: $0, now: now) } ?? "--",
            premium: risk.premiumPercent.map { PriceFormatting.percent($0, signed: true) }
                ?? (contract.marketKind == .inversePerpetual ? "不可用" : "--"),
            isStale: detailsStale
        )
    }

    private static func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        return String(format: "%02d:%02d:%02d", seconds / 3600,
                      (seconds % 3600) / 60, seconds % 60)
    }
}
