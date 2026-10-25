import Combine
import Foundation
import MarkBarCore

enum TideMessageKind: Equatable {
    case info, loading, success, error
}

enum TideNotificationPermission: Equatable {
    case notDetermined, authorized, denied, unavailable, failed
}

struct TideAdvancedSettingsState: Equatable {
    var showsCoinIcons = false
    var automaticallyChecksForUpdates = true
    var canChangeAutomaticChecks = false
    var loginStatus: LoginItemStatus = .unknown
    var loginError: String?
    var loginIsBusy = false
    var canManageLoginItem = false
}

@MainActor
final class TideSettingsModel: ObservableObject {
    @Published var preferences: TidePreferences
    @Published var catalogue: [Contract] = []
    @Published var catalogLoading = false
    @Published var connectionTesting = false
    @Published var connectionDiagnostic: ConnectionDiagnosticReport?
    @Published var message = ""
    @Published var messageKind: TideMessageKind = .info
    @Published var notificationStatus = "尚未启用通知"
    @Published var notificationPermission: TideNotificationPermission = .notDetermined
    @Published private(set) var advancedSettings = TideAdvancedSettingsState()

    var onChange: ((TidePreferences) -> Void)?
    var onSelectExchange: ((Exchange) -> Void)?
    var onReloadCatalog: (() -> Void)?
    var onTestConnection: (() -> Void)?
    var onRequestNotifications: (() -> Void)?
    var onOpenNotificationSettings: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onAcknowledgeAlert: ((UUID) -> Void)?
    var onSetCoinIcons: ((Bool) -> Void)?
    var onSetAutomaticChecks: ((Bool) -> Void)?
    var onSetLoginItem: ((Bool) -> Void)?
    var onOpenLoginSettings: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    private var messageRevision: UInt64 = 0

    init(preferences: TidePreferences) {
        self.preferences = preferences
    }

    func setMessage(_ text: String, kind: TideMessageKind, dismissAfter: TimeInterval? = nil) {
        messageRevision &+= 1
        let revision = messageRevision
        message = text
        messageKind = kind
        guard let dismissAfter, dismissAfter > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(dismissAfter * 1_000_000_000))
            guard let self, self.messageRevision == revision else { return }
            self.message = ""
        }
    }

    func setNotification(_ permission: TideNotificationPermission, status: String) {
        notificationPermission = permission
        notificationStatus = status
    }

    func setAdvancedSettings(_ state: TideAdvancedSettingsState) {
        guard state != advancedSettings else { return }
        advancedSettings = state
    }

    /// Only explicit user edits call this method. App-owned state updates can
    /// assign `preferences` directly without another persistence callback.
    func update(_ edit: (inout TidePreferences) -> Void) {
        var next = preferences
        edit(&next)
        next.normalize()
        preferences = next
        onChange?(next)
    }

    func moveContract(_ contract: Contract, offset: Int) {
        guard let index = preferences.watchlist.firstIndex(where: { $0.id == contract.id }),
              preferences.watchlist.indices.contains(index + offset) else { return }
        update { $0.watchlist.swapAt(index, index + offset) }
    }

    func setPinned(_ contractID: String, position: Int) {
        guard (0...1).contains(position) else { return }
        guard contractID.isEmpty || preferences.watchlist.contains(where: { $0.id == contractID }) else { return }
        update { preferences in
            var pins = preferences.pinnedIDs
            if contractID.isEmpty {
                if pins.indices.contains(position) { pins.remove(at: position) }
            } else if let existing = pins.firstIndex(of: contractID) {
                if pins.indices.contains(position) { pins.swapAt(existing, position) }
            } else if pins.indices.contains(position) {
                pins[position] = contractID
            } else {
                pins.append(contractID)
            }
            preferences.pinnedIDs = pins
        }
    }

    /// Accept a plain positive decimal without grouping, exponents, partial
    /// parses or values that exceed Decimal's significant-digit capacity.
    static func parseAlertThreshold(_ text: String) -> Decimal? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 160,
              text.range(of: "^(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$", options: .regularExpression) != nil else { return nil }
        let significant = text.filter { $0 != "." }.drop(while: { $0 == "0" })
        guard significant.count <= 38,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value > 0 else { return nil }
        return value
    }
}
