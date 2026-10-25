import Foundation

public enum Exchange: String, CaseIterable, Codable, Sendable {
    case okx, binance, bybit

    public var title: String {
        switch self {
        case .okx: return "OKX"
        case .binance: return "Binance"
        case .bybit: return "Bybit"
        }
    }

    public var markTimeDescription: String {
        switch self {
        case .okx: return "接口数据返回时间"
        case .binance: return "标记价接口时间"
        case .bybit: return "服务器响应时间（非标记价计算时间）"
        }
    }
}

public enum MarketKind: String, CaseIterable, Codable, Sendable {
    case spot
    case linearPerpetual
    case inversePerpetual

    public var title: String {
        switch self {
        case .spot: return "现货"
        case .linearPerpetual: return "USDT 永续"
        case .inversePerpetual: return "币本位永续"
        }
    }

    public var isPerpetual: Bool { self != .spot }

    public var usageDescription: String {
        switch self {
        case .spot:
            return "看实际成交市场，主报价为最新成交价。"
        case .linearPerpetual:
            return "看 USDT 结算合约风险价，主报价为标记价。"
        case .inversePerpetual:
            return "看 USD 报价、标的币结算合约风险价，主报价为标记价。"
        }
    }
}

public enum PriceKind: String, Codable, Sendable {
    case last
    case mark

    public var title: String {
        switch self {
        case .last: return "最新成交价"
        case .mark: return "标记价"
        }
    }
}

public struct Contract: Codable, Hashable, Sendable, Identifiable {
    public let exchange: Exchange
    public let instrumentID: String
    public let symbol: String
    public let marketKind: MarketKind
    public let quoteCurrency: String
    public let settlementCurrency: String
    public let priceKind: PriceKind

    public var id: String {
        // Preserve the persisted identity used by every release before multi-market support.
        if marketKind == .linearPerpetual, quoteCurrency == "USDT",
           settlementCurrency == "USDT", priceKind == .mark {
            return "\(exchange.rawValue):USDT:perpetual:mark:\(instrumentID)"
        }
        return "\(exchange.rawValue):\(quoteCurrency):\(marketKind.rawValue):\(priceKind.rawValue):\(settlementCurrency):\(instrumentID)"
    }

    public var pairTitle: String { "\(symbol)/\(quoteCurrency)" }
    public var displayTitle: String { "\(pairTitle) · \(marketKind.title)" }
    public var priceTitle: String { priceKind.title }
    public var compactTitle: String {
        switch marketKind {
        case .spot: return "\(symbol)现"
        case .linearPerpetual: return "\(symbol)永"
        case .inversePerpetual: return "\(symbol)币"
        }
    }
    public var dataTimeDescription: String {
        if exchange == .binance, marketKind == .spot { return "24 小时行情统计截止时间" }
        return exchange.markTimeDescription
    }
    public var hasValidMarketIdentity: Bool {
        guard !instrumentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch marketKind {
        case .spot:
            return quoteCurrency == "USDT" && settlementCurrency == "USDT" && priceKind == .last
        case .linearPerpetual:
            return quoteCurrency == "USDT" && settlementCurrency == "USDT" && priceKind == .mark
        case .inversePerpetual:
            return quoteCurrency == "USD" && settlementCurrency == symbol && priceKind == .mark
        }
    }

    public init(exchange: Exchange, instrumentID: String, symbol: String,
                marketKind: MarketKind = .linearPerpetual,
                quoteCurrency: String = "USDT", settlementCurrency: String = "USDT",
                priceKind: PriceKind = .mark) {
        self.exchange = exchange
        self.instrumentID = instrumentID
        self.symbol = symbol
        self.marketKind = marketKind
        self.quoteCurrency = quoteCurrency
        self.settlementCurrency = settlementCurrency
        self.priceKind = priceKind
    }

    private enum CodingKeys: String, CodingKey {
        case exchange, instrumentID, symbol, marketKind, quoteCurrency, settlementCurrency, priceKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exchange = try container.decode(Exchange.self, forKey: .exchange)
        instrumentID = try container.decode(String.self, forKey: .instrumentID)
        symbol = try container.decode(String.self, forKey: .symbol)
        marketKind = try container.decodeIfPresent(MarketKind.self, forKey: .marketKind) ?? .linearPerpetual
        quoteCurrency = try container.decodeIfPresent(String.self, forKey: .quoteCurrency) ?? "USDT"
        settlementCurrency = try container.decodeIfPresent(String.self, forKey: .settlementCurrency) ?? "USDT"
        priceKind = try container.decodeIfPresent(PriceKind.self, forKey: .priceKind) ?? .mark
    }

    public static let btc = Contract(exchange: .okx, instrumentID: "BTC-USDT-SWAP", symbol: "BTC")
    public static let eth = Contract(exchange: .okx, instrumentID: "ETH-USDT-SWAP", symbol: "ETH")
    public static let allCases: [Contract] = [.btc, .eth]

    public static func == (lhs: Contract, rhs: Contract) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct MarketDetails: Sendable {
    public let lastPrice: Decimal?
    /// Percentage points: 1.2 means +1.2%, not a ratio of 1.2.
    public let change24hPercent: Decimal?
    /// Raw funding ratio: 0.0001 means 0.01%.
    public let fundingRate: Decimal?
    public let nextFundingTime: Date?
    /// Local completion time for these supplemental details, not a mark-price timestamp.
    public let updatedAt: Date

    public init(lastPrice: Decimal?, change24hPercent: Decimal?, fundingRate: Decimal?, nextFundingTime: Date?, updatedAt: Date) {
        self.lastPrice = lastPrice
        self.change24hPercent = change24hPercent
        self.fundingRate = fundingRate
        self.nextFundingTime = nextFundingTime
        self.updatedAt = updatedAt
    }
}

public struct MarkQuote: Sendable, Equatable {
    public let contract: Contract
    public let price: Decimal
    /// The exchange API timestamp, not necessarily trade time or the underlying
    /// mark calculation time. For Bybit this is the response server time.
    public let dataTime: Date
    public let receivedAt: Date

    public init(contract: Contract, price: Decimal, dataTime: Date, receivedAt: Date) {
        self.contract = contract
        self.price = price
        self.dataTime = dataTime
        self.receivedAt = receivedAt
    }
}

public struct QuoteEntry: Sendable {
    public let quote: MarkQuote?
    public let lastError: String?

    public init(quote: MarkQuote? = nil, lastError: String? = nil) {
        self.quote = quote
        self.lastError = lastError
    }

    public func isStale(at now: Date, threshold: TimeInterval = 20) -> Bool {
        guard let quote else { return true }
        let age = now.timeIntervalSince(quote.dataTime)
        return !age.isFinite || !threshold.isFinite || threshold <= 0 || age > threshold || age < -30
    }
}

public struct QuoteBook: Sendable {
    public private(set) var entries: [Contract: QuoteEntry] = [:]

    public init() {}

    public func entry(for contract: Contract) -> QuoteEntry {
        entries[contract] ?? QuoteEntry()
    }

    /// Only a strictly newer timestamp advances a quote. An unchanged price can
    /// still be fresh, whereas a duplicate timestamp must not renew freshness.
    @discardableResult
    public mutating func apply(_ quote: MarkQuote, now: Date = Date()) -> Bool {
        guard !quote.price.isNaN, quote.price > 0,
              quote.dataTime.timeIntervalSince1970.isFinite,
              quote.dataTime.timeIntervalSince(now) <= 30 else {
            recordFailure(quote.contract, message: "行情价格或时间无效")
            return false
        }
        if let existing = entries[quote.contract]?.quote,
           quote.dataTime <= existing.dataTime {
            return false
        }
        entries[quote.contract] = QuoteEntry(quote: quote)
        return true
    }

    public mutating func remove(_ contract: Contract) {
        entries.removeValue(forKey: contract)
    }

    public mutating func recordFailure(_ contract: Contract, message: String) {
        entries[contract] = QuoteEntry(quote: entries[contract]?.quote, lastError: message)
    }
}
