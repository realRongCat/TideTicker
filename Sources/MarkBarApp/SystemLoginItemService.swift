import MarkBarCore
import ServiceManagement

/// Called only by LoginItemMonitor's serial background queue. ServiceManagement
/// performs synchronous XPC, so even reading status must stay off the UI path.
struct SystemLoginItemService: LoginItemService {
    func perform(_ operation: LoginItemOperation) -> LoginItemResult {
        let service = SMAppService.mainApp
        let initial = service.status
        var error: String?
        do {
            switch operation {
            case .status:
                return LoginItemResult(status: Self.status(initial))
            case .registerIfNeeded:
                guard initial == .notRegistered || initial == .notFound else {
                    return LoginItemResult(status: Self.status(initial))
                }
                try service.register()
            case .toggle:
                if initial == .enabled || initial == .requiresApproval {
                    try service.unregister()
                } else {
                    try service.register()
                }
            }
        } catch let failure {
            error = failure.localizedDescription
        }
        return LoginItemResult(status: Self.status(service.status), error: error)
    }

    private static func status(_ value: SMAppService.Status) -> LoginItemStatus {
        switch value {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
}
