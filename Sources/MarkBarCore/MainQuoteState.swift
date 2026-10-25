import Foundation

public enum MainQuoteRoute: String, Sendable, Equatable {
    case webSocket
    case restFallback
    case restOnly

    public var title: String {
        switch self {
        case .webSocket: return "WebSocket"
        case .restFallback: return "REST 兜底"
        case .restOnly: return "REST 采样"
        }
    }
}

public enum QuoteCoverageGap: String, Sendable, Equatable {
    case startup
    case disconnected
    case fallbackPolling
    case pollingOnly
    case sleeping
    case consumerLag
    case routeChanged
    case sourceChanged

    public var title: String {
        switch self {
        case .startup: return "等待连续行情"
        case .disconnected: return "WebSocket 已断开"
        case .fallbackPolling: return "使用 REST 兜底"
        case .pollingOnly: return "REST 采样可能漏过短暂触价"
        case .sleeping: return "休眠期间未观察行情"
        case .consumerLag: return "行情处理延迟，可能漏过触价"
        case .routeChanged: return "网络路径已切换"
        case .sourceChanged: return "行情来源已切换"
        }
    }
}

public enum QuoteContinuity: Sendable, Equatable {
    case continuous(since: Date)
    case possiblyMissed(since: Date, cause: QuoteCoverageGap)
    case suspended(since: Date)

    public var possiblyMissed: Bool {
        switch self {
        case .continuous: return false
        case .possiblyMissed, .suspended: return true
        }
    }

    public var description: String {
        switch self {
        case .continuous: return "连续行情"
        case .possiblyMissed(_, let cause): return cause.title
        case .suspended: return "休眠期间可能漏报"
        }
    }
}

public struct MainQuoteObservation: Sendable, Equatable {
    public let quote: MarkQuote
    public let continuityEpoch: UInt64
    public let continuity: QuoteContinuity
    public let route: MainQuoteRoute

    public init(quote: MarkQuote, continuityEpoch: UInt64,
                continuity: QuoteContinuity, route: MainQuoteRoute) {
        self.quote = quote
        self.continuityEpoch = continuityEpoch
        self.continuity = continuity
        self.route = route
    }
}

public struct MainQuoteState: Sendable {
    public let contract: Contract
    public let entry: QuoteEntry
    public let isStale: Bool
    public let continuityEpoch: UInt64
    public let continuity: QuoteContinuity
    public let route: MainQuoteRoute?

    public var possiblyMissed: Bool { continuity.possiblyMissed }

    public init(contract: Contract, entry: QuoteEntry, isStale: Bool,
                continuityEpoch: UInt64, continuity: QuoteContinuity,
                route: MainQuoteRoute?) {
        self.contract = contract
        self.entry = entry
        self.isStale = isStale
        self.continuityEpoch = continuityEpoch
        self.continuity = continuity
        self.route = route
    }
}

public struct MainQuoteStateBook: Sendable {
    private struct Coverage: Sendable {
        var epoch: UInt64
        var continuity: QuoteContinuity
        var route: MainQuoteRoute?
    }

    private var book = QuoteBook()
    private var coverage: [Contract: Coverage] = [:]

    public init() {}

    public mutating func replaceContracts(_ contracts: [Contract], preserveQuotes: Bool,
                                          gap: QuoteCoverageGap, now: Date = Date()) {
        let allowed = Set(contracts)
        if !preserveQuotes { book = QuoteBook() }
        for contract in book.entries.keys where !allowed.contains(contract) { book.remove(contract) }
        coverage = Dictionary(uniqueKeysWithValues: contracts.map { contract in
            let previous = coverage[contract]
            return (contract, Coverage(
                epoch: (previous?.epoch ?? 0) &+ 1,
                continuity: .possiblyMissed(since: now, cause: gap),
                route: previous?.route
            ))
        })
    }

    public mutating func markGap(_ gap: QuoteCoverageGap, contracts: [Contract]? = nil,
                                 now: Date = Date()) {
        let targets = contracts ?? Array(coverage.keys)
        for contract in targets {
            guard var value = coverage[contract] else { continue }
            if case .continuous = value.continuity { value.epoch &+= 1 }
            value.continuity = .possiblyMissed(since: now, cause: gap)
            coverage[contract] = value
        }
    }

    public mutating func suspend(now: Date = Date()) {
        for contract in coverage.keys {
            guard var value = coverage[contract] else { continue }
            value.epoch &+= 1
            value.continuity = .suspended(since: now)
            coverage[contract] = value
        }
    }

    @discardableResult
    public mutating func apply(_ quote: MarkQuote, route: MainQuoteRoute,
                               now: Date = Date()) -> MainQuoteObservation? {
        guard var value = coverage[quote.contract] else { return nil }
        guard book.apply(quote, now: now) else { return nil }
        if route == .webSocket, value.continuity.possiblyMissed {
            value.epoch &+= 1
            value.continuity = .continuous(since: now)
        } else if route != .webSocket, !value.continuity.possiblyMissed {
            value.epoch &+= 1
            value.continuity = .possiblyMissed(
                since: now,
                cause: route == .restOnly ? .pollingOnly : .fallbackPolling
            )
        }
        value.route = route
        coverage[quote.contract] = value
        return MainQuoteObservation(quote: quote, continuityEpoch: value.epoch,
                                    continuity: value.continuity, route: route)
    }

    public mutating func recordFailure(_ contract: Contract, message: String) {
        guard coverage[contract] != nil else { return }
        book.recordFailure(contract, message: message)
    }

    public func state(for contract: Contract, at now: Date,
                      staleAfter: TimeInterval) -> MainQuoteState {
        let value = coverage[contract] ?? Coverage(
            epoch: 0,
            continuity: .possiblyMissed(since: now, cause: .startup),
            route: nil
        )
        let entry = book.entry(for: contract)
        return MainQuoteState(contract: contract, entry: entry,
                              isStale: entry.quote != nil && entry.isStale(at: now, threshold: staleAfter),
                              continuityEpoch: value.epoch, continuity: value.continuity,
                              route: value.route)
    }

    public func states(for contracts: [Contract], at now: Date,
                       staleAfter: TimeInterval) -> [String: MainQuoteState] {
        Dictionary(uniqueKeysWithValues: contracts.map {
            ($0.id, state(for: $0, at: now, staleAfter: staleAfter))
        })
    }
}
