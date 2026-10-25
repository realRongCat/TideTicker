import Foundation

/// Persistable product settings. Storage and corrupt-file recovery belong to the app.
public struct TidePreferences: Codable, Equatable, Sendable {
    public var exchange: Exchange
    public var networkMode: NetworkMode
    public var watchlist: [Contract]
    public var pinnedIDs: [String]
    public var refreshInterval: TimeInterval
    public var showsMarketDetails: Bool
    public var alerts: [PriceAlert]
    public var pendingAlerts: [PendingAlertEvent]

    public init(exchange: Exchange = .okx, networkMode: NetworkMode = .system,
                watchlist: [Contract] = [.btc, .eth],
                pinnedIDs: [String] = [Contract.btc.id, Contract.eth.id],
                refreshInterval: TimeInterval = 5, showsMarketDetails: Bool = false,
                alerts: [PriceAlert] = [], pendingAlerts: [PendingAlertEvent] = []) {
        self.exchange = exchange
        self.networkMode = networkMode
        self.watchlist = watchlist
        self.pinnedIDs = pinnedIDs
        self.refreshInterval = refreshInterval
        self.showsMarketDetails = showsMarketDetails
        self.alerts = alerts
        self.pendingAlerts = pendingAlerts
    }

    private enum CodingKeys: String, CodingKey {
        case exchange, networkMode, watchlist, pinnedIDs
        case refreshInterval, showsMarketDetails, alerts, pendingAlerts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exchange = try container.decode(Exchange.self, forKey: .exchange)
        // Only pre-existing configurations without this field retain physical
        // direct access. A new installation defaults to system networking.
        if container.contains(.networkMode) {
            networkMode = try container.decode(NetworkMode.self, forKey: .networkMode)
        } else {
            networkMode = .physicalDirect
        }
        // Invalid explicit modes and missing original required fields remain
        // decoding errors, handled by the app's existing corrupt-file flow.
        watchlist = try container.decode([Contract].self, forKey: .watchlist)
        pinnedIDs = try container.decode([String].self, forKey: .pinnedIDs)
        refreshInterval = try container.decode(TimeInterval.self, forKey: .refreshInterval)
        showsMarketDetails = try container.decode(Bool.self, forKey: .showsMarketDetails)
        alerts = try container.decode([PriceAlert].self, forKey: .alerts)
        pendingAlerts = try container.decodeIfPresent([PendingAlertEvent].self, forKey: .pendingAlerts) ?? []
    }

    public static let `default` = TidePreferences()

    /// An empty slot remains empty; monitoring a contract does not implicitly pin it.
    public var pinnedContracts: [Contract] {
        let available = Dictionary(uniqueKeysWithValues: normalizedWatchlist().map { ($0.id, $0) })
        var seen = Set<String>()
        return Array(pinnedIDs.compactMap { id -> Contract? in
            guard seen.insert(id).inserted else { return nil }
            return available[id]
        }.prefix(2))
    }

    public var staleAfter: TimeInterval { max(20, refreshInterval * 3) }

    public mutating func normalize() {
        watchlist = normalizedWatchlist()
        let available = Dictionary(uniqueKeysWithValues: watchlist.map { ($0.id, $0) })
        var seenPins = Set<String>()
        let normalizedPins = pinnedIDs.compactMap { id -> String? in
            guard available[id] != nil, seenPins.insert(id).inserted else { return nil }
            return id
        }.prefix(2)
        pinnedIDs = Array(normalizedPins)
        if ![5.0, 10, 15, 30].contains(refreshInterval) { refreshInterval = 5 }

        var seenAlerts = Set<UUID>()
        alerts = alerts.compactMap { original in
            guard original.hasValidThreshold,
                  let contract = available[original.contract.id],
                  seenAlerts.insert(original.id).inserted else { return nil }
            var alert = original
            // The watchlist is authoritative for display metadata such as symbol.
            alert.contract = contract
            if !alert.cooldown.isFinite || alert.cooldown < 0 { alert.cooldown = 300 }
            if let lastTriggeredAt = alert.lastTriggeredAt,
               !lastTriggeredAt.timeIntervalSince1970.isFinite {
                alert.lastTriggeredAt = nil
            }
            return alert
        }
        let alertIDs = Set(alerts.filter(\.requiresAcknowledgement).map(\.id))
        var seenPending = Set<UUID>()
        pendingAlerts = pendingAlerts.filter {
            alertIDs.contains($0.ruleID) && seenPending.insert($0.ruleID).inserted
        }
    }

    private func normalizedWatchlist() -> [Contract] {
        var seen = Set<String>()
        return Array(watchlist.filter { contract in
            contract.exchange == exchange
                && contract.hasValidMarketIdentity
                && seen.insert(contract.id).inserted
        }.prefix(20))
    }
}
