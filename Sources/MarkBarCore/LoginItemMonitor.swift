import Foundation

public enum LoginItemStatus: Sendable, Equatable {
    case unknown
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

public enum LoginItemOperation: Sendable, Equatable {
    case status
    case registerIfNeeded
    case toggle
}

public struct LoginItemResult: Sendable, Equatable {
    public let status: LoginItemStatus
    public let error: String?

    public init(status: LoginItemStatus, error: String? = nil) {
        self.status = status
        self.error = error
    }
}

/// Implementations are created without MainActor isolation and may perform blocking OS calls.
public protocol LoginItemService: Sendable {
    func perform(_ operation: LoginItemOperation) -> LoginItemResult
}

public struct LoginItemState: Sendable, Equatable {
    public let status: LoginItemStatus
    public let error: String?
    public let isBusy: Bool
}

/// The UI only reads this cache. System reads and mutations share one utility queue.
@MainActor
public final class LoginItemMonitor {
    public private(set) var state = LoginItemState(status: .unknown, error: nil, isBusy: false)
    public var status: LoginItemStatus { state.status }
    public var error: String? { state.error }
    public var isBusy: Bool { state.isBusy }
    public var onChange: (@MainActor () -> Void)?

    private let service: any LoginItemService
    private let queue = DispatchQueue(label: "TideTicker.LoginItemMonitor", qos: .utility)
    private let refreshInterval: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private var lastRequestAt: TimeInterval?
    private var requestID: UUID?
    private var isStopped = false

    public init(service: any LoginItemService, refreshInterval: TimeInterval = 30,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.service = service
        self.refreshInterval = refreshInterval.isFinite ? max(0, refreshInterval) : 30
        self.clock = clock
    }

    /// Calls made while busy share the current refresh; no follow-up work is enqueued.
    @discardableResult
    public func refreshIfNeeded(now: TimeInterval? = nil, force: Bool = false) -> Bool {
        guard !isStopped, !isBusy else { return false }
        let current = now ?? clock()
        if !force, let previous = lastRequestAt, current - previous < refreshInterval {
            return false
        }
        return request(operation: .status, now: current)
    }

    /// Explicit commands bypass the refresh TTL but are rejected while any work is in flight.
    @discardableResult
    public func request(operation: LoginItemOperation, now: TimeInterval? = nil) -> Bool {
        guard !isStopped, !isBusy else { return false }
        let id = UUID()
        requestID = id
        lastRequestAt = now ?? clock()
        state = LoginItemState(status: status, error: operation == .status ? error : nil, isBusy: true)
        onChange?()
        // A UI callback can stop the monitor before the work is submitted.
        guard !isStopped, requestID == id else { return true }
        let service = self.service
        queue.async { [weak self] in
            let result = service.perform(operation)
            Task { @MainActor [weak self] in
                self?.complete(result, operation: operation, requestID: id)
            }
        }
        return true
    }

    /// Terminal: a blocking OS call may finish later, but it cannot publish or enqueue more work.
    public func stop() {
        isStopped = true
        requestID = nil
        onChange = nil
        state = LoginItemState(status: status, error: error, isBusy: false)
    }

    private func complete(_ result: LoginItemResult, operation: LoginItemOperation, requestID id: UUID) {
        guard !isStopped, requestID == id else { return }
        requestID = nil
        // A successful background poll must not erase a registration/toggle failure.
        let nextError = operation == .status ? (error ?? result.error) : result.error
        state = LoginItemState(status: result.status, error: nextError, isBusy: false)
        onChange?()
    }
}
