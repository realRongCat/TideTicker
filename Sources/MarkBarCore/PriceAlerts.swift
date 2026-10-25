import Foundation

public enum AlertDirection: String, Codable, CaseIterable, Sendable {
    // Keep the legacy raw values for saved upward/downward crossing rules.
    case crossing, above, below, greaterThan, lessThan

    public var title: String {
        switch self {
        case .crossing: return "穿越"
        case .above: return "上穿"
        case .below: return "下穿"
        case .greaterThan: return "大于"
        case .lessThan: return "小于"
        }
    }
}

public enum SimpleAlertTemplate: String, CaseIterable, Sendable {
    case risesTo
    case fallsTo

    public var title: String {
        switch self {
        case .risesTo: return "涨到"
        case .fallsTo: return "跌到"
        }
    }

    public var direction: AlertDirection {
        switch self {
        case .risesTo: return .above
        case .fallsTo: return .below
        }
    }
}

public struct PriceAlert: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var contract: Contract
    public var direction: AlertDirection
    public var threshold: Decimal
    public var isEnabled: Bool
    public var repeats: Bool
    public var cooldown: TimeInterval
    public var lastTriggeredAt: Date?
    public var requiresAcknowledgement: Bool

    public init(id: UUID = UUID(), contract: Contract, direction: AlertDirection, threshold: Decimal,
                isEnabled: Bool = true, repeats: Bool = false, cooldown: TimeInterval = 60,
                lastTriggeredAt: Date? = nil, requiresAcknowledgement: Bool = false) {
        self.id = id
        self.contract = contract
        self.direction = direction
        self.threshold = threshold
        self.isEnabled = isEnabled
        self.repeats = repeats
        self.cooldown = cooldown
        self.lastTriggeredAt = lastTriggeredAt
        self.requiresAcknowledgement = requiresAcknowledgement
    }

    private enum CodingKeys: String, CodingKey {
        case id, contract, direction, threshold, isEnabled, repeats, cooldown, lastTriggeredAt
        case requiresAcknowledgement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        contract = try container.decode(Contract.self, forKey: .contract)
        direction = try container.decode(AlertDirection.self, forKey: .direction)
        threshold = try container.decode(Decimal.self, forKey: .threshold)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        repeats = try container.decode(Bool.self, forKey: .repeats)
        cooldown = try container.decode(TimeInterval.self, forKey: .cooldown)
        lastTriggeredAt = try container.decodeIfPresent(Date.self, forKey: .lastTriggeredAt)
        requiresAcknowledgement = try container.decodeIfPresent(Bool.self, forKey: .requiresAcknowledgement) ?? false
    }

    var hasValidThreshold: Bool { !threshold.isNaN && threshold > 0 }
}

public struct PendingAlertEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { ruleID }
    public let ruleID: UUID
    public let contract: Contract
    public let threshold: Decimal
    public let direction: AlertDirection
    public var latestPrice: Decimal
    public var firstTriggeredAt: Date
    public var latestTriggeredAt: Date

    public init(event: AlertEvent) {
        ruleID = event.id
        contract = event.contract
        threshold = event.threshold
        direction = event.direction
        latestPrice = event.price
        firstTriggeredAt = event.time
        latestTriggeredAt = event.time
    }

    public mutating func update(with event: AlertEvent) {
        guard event.id == ruleID else { return }
        latestPrice = event.price
        latestTriggeredAt = event.time
    }
}

public struct AlertEvent: Equatable, Identifiable, Sendable {
    /// The originating rule ID, not a separate delivery identifier.
    public let id: UUID
    public let contract: Contract
    public let price: Decimal
    public let threshold: Decimal
    public let direction: AlertDirection
    public let time: Date

    public init(id: UUID, contract: Contract, price: Decimal, threshold: Decimal,
                direction: AlertDirection, time: Date) {
        self.id = id
        self.contract = contract
        self.price = price
        self.threshold = threshold
        self.direction = direction
        self.time = time
    }
}

/// Evaluates fresh prices against crossing or current-value conditions.
/// Crossings need a continuous baseline; current-value conditions do not infer
/// past movement and can match the first fresh quote after startup or a gap.
/// The app should reset when it changes configuration, including off/on edits
/// that could otherwise happen entirely between two calls to evaluate.
public struct PriceAlertEngine: Sendable {
    private struct Observation: Sendable {
        let price: Decimal
        let dataTime: Date
    }

    private struct RuleState: Sendable {
        var rule: PriceAlert
        var baseline: Observation?
    }

    private var states: [UUID: RuleState] = [:]
    private var latestDataTimes: [String: Date] = [:]

    public init() {}

    public mutating func reset() {
        states.removeAll()
        latestDataTimes.removeAll()
    }

    public mutating func reset(contractID: String) {
        states = states.filter { $0.value.rule.contract.id != contractID }
        latestDataTimes.removeValue(forKey: contractID)
    }

    public mutating func reset(ruleID: UUID) {
        states.removeValue(forKey: ruleID)
    }

    public mutating func evaluate(_ quote: MarkQuote, rules: inout [PriceAlert],
                                  now: Date = Date(), staleAfter: TimeInterval = 20) -> [AlertEvent] {
        let ruleIDs = Set(rules.map(\.id))
        states = states.filter { ruleIDs.contains($0.key) }
        var seen = Set<UUID>()
        for rule in rules where seen.insert(rule.id).inserted {
            if states[rule.id]?.rule != rule {
                states[rule.id] = RuleState(rule: rule, baseline: nil)
            }
        }

        let key = quote.contract.id
        // A duplicate or late response cannot move the baseline, even if its price differs.
        if let latest = latestDataTimes[key], quote.dataTime <= latest { return [] }
        guard !quote.price.isNaN, quote.price > 0,
              now.timeIntervalSince1970.isFinite,
              quote.dataTime.timeIntervalSince1970.isFinite,
              !QuoteEntry(quote: quote).isStale(at: now, threshold: staleAfter) else {
            for id in states.keys where states[id]?.rule.contract.id == key {
                states[id]?.baseline = nil
            }
            return []
        }
        latestDataTimes[key] = quote.dataTime

        var events: [AlertEvent] = []
        seen.removeAll()
        for index in rules.indices {
            var rule = rules[index]
            guard seen.insert(rule.id).inserted, rule.contract.id == key,
                  var state = states[rule.id] else { continue }
            guard rule.isEnabled, rule.hasValidThreshold,
                  rule.cooldown.isFinite, rule.cooldown >= 0 else {
                state.baseline = nil
                states[rule.id] = state
                continue
            }

            let previous = state.baseline
            state.baseline = Observation(price: quote.price, dataTime: quote.dataTime)
            let matches: Bool
            switch rule.direction {
            case .greaterThan:
                matches = quote.price > rule.threshold
            case .lessThan:
                matches = quote.price < rule.threshold
            case .crossing, .above, .below:
                // This also covers a sleep/disconnection gap with no response.
                guard let previous,
                      now.timeIntervalSince(previous.dataTime) <= staleAfter,
                      now.timeIntervalSince(previous.dataTime) >= -30 else {
                    states[rule.id] = state
                    continue
                }
                let upward = previous.price < rule.threshold && quote.price >= rule.threshold
                let downward = previous.price > rule.threshold && quote.price <= rule.threshold
                matches = (rule.direction != .below && upward) || (rule.direction != .above && downward)
            }
            let cooledDown = !rule.repeats || rule.lastTriggeredAt.map {
                let elapsed = now.timeIntervalSince($0)
                return elapsed.isFinite && elapsed >= rule.cooldown
            } ?? true

            if matches && cooledDown {
                events.append(AlertEvent(id: rule.id, contract: rule.contract, price: quote.price,
                                         threshold: rule.threshold, direction: rule.direction, time: now))
                if !rule.requiresAcknowledgement {
                    rule.lastTriggeredAt = now
                    if !rule.repeats { rule.isEnabled = false }
                }
                rules[index] = rule
                state.rule = rule
            }
            // Crossings suppressed by cooldown are not delivered later while still above/below.
            states[rule.id] = state
        }
        return events
    }
}
