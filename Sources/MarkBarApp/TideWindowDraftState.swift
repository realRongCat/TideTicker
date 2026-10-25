import Combine
import Foundation
import MarkBarCore

/// Keep in-progress input when navigating between pages of the retained window.
/// The shell does not observe these low-frequency, page-specific draft models.
@MainActor
final class TideWatchlistDraft: ObservableObject {
    @Published var search = ""
    @Published var marketKind: MarketKind? = nil
}

enum TideAlertComposerMode: String, CaseIterable {
    case simple
    case advanced

    var title: String {
        switch self {
        case .simple: return "简单"
        case .advanced: return "高级"
        }
    }
}

@MainActor
final class TideAlertDraft: ObservableObject {
    @Published var editingAlertID: UUID?
    @Published var selectedContractID = ""
    @Published var mode: TideAlertComposerMode = .simple
    @Published var direction: AlertDirection = .above
    @Published var threshold = ""
    @Published var repeats = false
    @Published var requiresAcknowledgement = false
    @Published var validation = ""
    @Published var validationIsError = false
}
