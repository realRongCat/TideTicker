import Combine
import Foundation
import MarkBarCore

/// A view-only snapshot of the existing quote cache. This model never requests
/// or collects market data, and is published only while the overview is visible.
struct TideOverviewQuote: Equatable {
    let contract: Contract
    let price: Decimal?
    let dataTime: Date?
    let receivedAt: Date?
    let isStale: Bool
    let possiblyMissed: Bool
    let error: String?
    let supplement: TideOverviewSupplement?
}

struct TideOverviewSupplement: Equatable {
    let change24h: String
    let fundingRate: String?
    let fundingCountdown: String?
    let premium: String?
    let isStale: Bool
}

@MainActor
final class TideOverviewModel: ObservableObject {
    struct Snapshot: Equatable {
        var rows: [TideOverviewQuote] = []
        var isRefreshing = false
        var isPaused = false
    }

    @Published private(set) var snapshot = Snapshot()

    func update(_ rows: [TideOverviewQuote], isRefreshing: Bool, isPaused: Bool) {
        let next = Snapshot(rows: rows, isRefreshing: isRefreshing, isPaused: isPaused)
        guard next != snapshot else { return }
        snapshot = next
    }
}
