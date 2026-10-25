import Foundation

public struct MainQuotePlan: Sendable, Equatable {
    public let exchange: Exchange
    public let networkMode: NetworkMode
    public let contracts: [Contract]
    public let restInterval: TimeInterval
    public let staleAfter: TimeInterval

    public init(exchange: Exchange, networkMode: NetworkMode, contracts: [Contract],
                restInterval: TimeInterval, staleAfter: TimeInterval) {
        self.exchange = exchange
        self.networkMode = networkMode
        self.contracts = contracts
        self.restInterval = restInterval
        self.staleAfter = staleAfter
    }

    public init(preferences: TidePreferences) {
        self.init(exchange: preferences.exchange, networkMode: preferences.networkMode,
                  contracts: preferences.watchlist, restInterval: preferences.refreshInterval,
                  staleAfter: preferences.staleAfter)
    }
}

public enum MainQuoteSessionPhase: Sendable, Equatable {
    case stopped
    case connecting
    case streaming
    case restFallback(attempt: Int)
    case restOnly(NetworkMode)
    case suspended

    public var title: String {
        switch self {
        case .stopped: return "已停止"
        case .connecting: return "正在连接 WebSocket"
        case .streaming: return "WebSocket 连续行情"
        case .restFallback: return "REST 兜底 · 可能漏报"
        case .restOnly: return "REST 采样 · 可能漏报"
        case .suspended: return "休眠暂停"
        }
    }

    public var isBusy: Bool {
        switch self {
        case .connecting, .restFallback: return true
        default: return false
        }
    }
}

public struct MainQuoteSnapshot: Sendable {
    public let revision: UInt64
    public let phase: MainQuoteSessionPhase
    public let entries: [String: MainQuoteState]
    public let observedAt: Date

    public init(revision: UInt64, phase: MainQuoteSessionPhase,
                entries: [String: MainQuoteState], observedAt: Date) {
        self.revision = revision
        self.phase = phase
        self.entries = entries
        self.observedAt = observedAt
    }

    public func state(for contract: Contract) -> MainQuoteState? { entries[contract.id] }
}

public struct MainQuoteUpdate: Sendable {
    public let snapshot: MainQuoteSnapshot
    public let advancedQuotes: [MainQuoteObservation]
}

public enum MainQuoteSessionError: LocalizedError, Sendable {
    case tooManyContracts
    case mixedExchange
    case duplicateContract
    case invalidInterval

    public var errorDescription: String? {
        switch self {
        case .tooManyContracts: return "最多关注 20 个品种"
        case .mixedExchange: return "主报价会话不能混合不同交易所"
        case .duplicateContract: return "主报价会话包含重复品种"
        case .invalidInterval: return "主报价 REST 间隔无效"
        }
    }
}

struct MainQuoteFetchResult: Sendable {
    let contract: Contract
    let quote: MarkQuote?
    let error: String?
}

enum MainQuoteStreamEvent: Sendable, Equatable {
    case subscribed(Contract)
    case quote(MarkQuote)
    case subscriptionFailed(Contract, String)
}

protocol MainQuoteFeedAdapter: Sendable {
    var supportsStreaming: Bool { get }
    func stream(contracts: [Contract]) async -> AsyncThrowingStream<MainQuoteStreamEvent, Error>
    func fetch(_ contract: Contract) async -> MainQuoteFetchResult
    func cancelAll() async
}

protocol MainQuoteFeedFactory: Sendable {
    func make(exchange: Exchange, networkMode: NetworkMode) -> any MainQuoteFeedAdapter
}

struct LiveMainQuoteFeedFactory: MainQuoteFeedFactory {
    func make(exchange: Exchange, networkMode: NetworkMode) -> any MainQuoteFeedAdapter {
        LiveMainQuoteFeed(exchange: exchange, networkMode: networkMode)
    }
}

actor LiveMainQuoteFeed: MainQuoteFeedAdapter {
    nonisolated let supportsStreaming: Bool
    private let client: MarketDataClient
    private let webSocket: OKXWebSocketClient?

    init(exchange: Exchange, networkMode: NetworkMode) {
        supportsStreaming = exchange == .okx && networkMode == .system
        client = MarketDataClient(networkMode: networkMode)
        webSocket = supportsStreaming ? OKXWebSocketClient() : nil
    }

    func stream(contracts: [Contract]) async -> AsyncThrowingStream<MainQuoteStreamEvent, Error> {
        guard let webSocket else {
            return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
        }
        return await webSocket.stream(contracts: contracts)
    }

    func fetch(_ contract: Contract) async -> MainQuoteFetchResult {
        do {
            return MainQuoteFetchResult(contract: contract,
                quote: try await client.fetch(contract), error: nil)
        } catch {
            return MainQuoteFetchResult(contract: contract,
                quote: nil, error: error.localizedDescription)
        }
    }

    func cancelAll() async {
        await webSocket?.cancelAll()
        await client.cancelAll()
    }
}

public actor MainQuoteSession {
    private let factory: any MainQuoteFeedFactory
    private let updatesStream: AsyncStream<MainQuoteUpdate>
    private let continuation: AsyncStream<MainQuoteUpdate>.Continuation
    private var plan: MainQuotePlan?
    private var feed: (any MainQuoteFeedAdapter)?
    private var stateBook = MainQuoteStateBook()
    private var phase: MainQuoteSessionPhase = .stopped
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var streamTask: Task<Void, Never>?
    private var restTask: Task<Void, Never>?
    private var staleTask: Task<Void, Never>?
    private var subscribedIDs = Set<String>()
    private var healthyStreamingIDs = Set<String>()
    private var lastStreamedAt: [String: Date] = [:]
    private var restStartOffset = 0
    private var consumerGapPending = false

    public init() {
        factory = LiveMainQuoteFeedFactory()
        let pair = AsyncStream<MainQuoteUpdate>.makeStream(bufferingPolicy: .bufferingOldest(64))
        updatesStream = pair.stream
        continuation = pair.continuation
    }

    init(factory: any MainQuoteFeedFactory) {
        self.factory = factory
        let pair = AsyncStream<MainQuoteUpdate>.makeStream(bufferingPolicy: .bufferingOldest(64))
        updatesStream = pair.stream
        continuation = pair.continuation
    }

    public func updates() -> AsyncStream<MainQuoteUpdate> { updatesStream }

    public func reconcile(_ next: MainQuotePlan) async throws {
        try Self.validate(next)
        if plan == next { return }
        let previous = plan
        generation &+= 1
        let currentGeneration = generation
        await cancelWork()
        let sourceChanged = previous?.exchange != nil && previous?.exchange != next.exchange
        let routeChanged = previous?.networkMode != nil && previous?.networkMode != next.networkMode
        stateBook.replaceContracts(next.contracts,
            preserveQuotes: !sourceChanged,
            gap: sourceChanged ? .sourceChanged : (routeChanged ? .routeChanged : .startup))
        plan = next
        subscribedIDs.removeAll()
        healthyStreamingIDs.removeAll()
        lastStreamedAt.removeAll()
        restStartOffset = 0
        feed = factory.make(exchange: next.exchange, networkMode: next.networkMode)
        guard !next.contracts.isEmpty else {
            phase = .stopped
            emit()
            return
        }
        startStaleClock(generation: currentGeneration)
        if feed?.supportsStreaming == true {
            phase = .connecting
            emit()
            startRESTLoop(route: .restFallback, generation: currentGeneration)
            startStreaming(generation: currentGeneration)
        } else {
            phase = .restOnly(next.networkMode)
            stateBook.markGap(.pollingOnly)
            emit()
            startRESTLoop(route: .restOnly, generation: currentGeneration)
        }
    }

    public func refreshNow() {
        guard let feed, plan != nil else { return }
        let currentGeneration = generation
        Task { [weak self] in
            let contracts = await self?.contractsNeedingREST(generation: currentGeneration) ?? []
            guard !contracts.isEmpty else { return }
            await self?.runRESTPass(contracts: contracts, feed: feed,
                                    route: feed.supportsStreaming ? .restFallback : .restOnly,
                                    generation: currentGeneration)
        }
    }

    public func suspend() async {
        generation &+= 1
        await cancelWork()
        phase = .suspended
        stateBook.suspend()
        emit()
    }

    public func resume() async throws {
        guard let plan else { return }
        self.plan = nil
        try await reconcile(plan)
    }

    public func stop() async {
        generation &+= 1
        await cancelWork()
        plan = nil
        phase = .stopped
        emit()
    }

    private static func validate(_ plan: MainQuotePlan) throws {
        guard plan.contracts.count <= 20 else { throw MainQuoteSessionError.tooManyContracts }
        guard plan.contracts.allSatisfy({ $0.exchange == plan.exchange && $0.hasValidMarketIdentity }) else {
            throw MainQuoteSessionError.mixedExchange
        }
        guard Set(plan.contracts.map(\.id)).count == plan.contracts.count else {
            throw MainQuoteSessionError.duplicateContract
        }
        guard plan.restInterval.isFinite, plan.restInterval > 0,
              plan.staleAfter.isFinite, plan.staleAfter > 0 else {
            throw MainQuoteSessionError.invalidInterval
        }
    }

    private func startStreaming(generation expected: UInt64) {
        guard let feed, let plan else { return }
        streamTask = Task { [weak self] in
            var attempt = 0
            while let self, !Task.isCancelled,
                  await self.generation == expected {
                do {
                    let stream = await feed.stream(contracts: plan.contracts)
                    for try await event in stream {
                        try Task.checkCancellation()
                        await self.accept(event, generation: expected)
                        attempt = 0
                    }
                    try Task.checkCancellation()
                    throw URLError(.networkConnectionLost)
                } catch is CancellationError {
                    return
                } catch {
                    guard await self.generation == expected, !Task.isCancelled else { return }
                    attempt = min(attempt + 1, 6)
                    await self.streamingFailed(error.localizedDescription, attempt: attempt,
                                               generation: expected)
                    let delay = min(30.0, pow(2, Double(attempt - 1)))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    private func streamingFailed(_ message: String, attempt: Int, generation expected: UInt64) {
        guard generation == expected, let plan else { return }
        subscribedIDs.removeAll()
        healthyStreamingIDs.removeAll()
        lastStreamedAt.removeAll()
        stateBook.markGap(.disconnected)
        for contract in plan.contracts { stateBook.recordFailure(contract, message: message) }
        phase = .restFallback(attempt: attempt)
        if restTask == nil { startRESTLoop(route: .restFallback, generation: expected) }
        emit()
    }

    private func startRESTLoop(route: MainQuoteRoute, generation expected: UInt64) {
        guard restTask == nil, let feed, let plan else { return }
        restTask = Task { [weak self] in
            let clock = ContinuousClock()
            let interval = Duration.seconds(plan.restInterval)
            var deadline = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                let contracts = await self.contractsNeedingREST(generation: expected)
                if !contracts.isEmpty {
                    let ordered = await self.rotateRESTOrder(contracts, generation: expected)
                    await self.runRESTPass(contracts: ordered, feed: feed,
                                           route: route, generation: expected)
                }
                guard !Task.isCancelled else { return }
                deadline += interval
                if deadline < clock.now { deadline = clock.now }
                try? await clock.sleep(until: deadline)
            }
        }
    }

    private func startStaleClock(generation expected: UInt64) {
        staleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled,
                      await self.generation == expected else { return }
                await self.expireInactiveStreams(generation: expected)
                await self.emit()
            }
        }
    }

    private func accept(_ event: MainQuoteStreamEvent, generation expected: UInt64) {
        guard generation == expected, let plan else { return }
        switch event {
        case .subscribed(let contract):
            guard plan.contracts.contains(contract) else { return }
            subscribedIDs.insert(contract.id)
        case .subscriptionFailed(let contract, let message):
            guard plan.contracts.contains(contract) else { return }
            subscribedIDs.remove(contract.id)
            healthyStreamingIDs.remove(contract.id)
            lastStreamedAt.removeValue(forKey: contract.id)
            stateBook.markGap(.fallbackPolling, contracts: [contract])
            stateBook.recordFailure(contract, message: message)
            phase = .restFallback(attempt: 0)
            emit()
        case .quote(let quote):
            accept(quote, route: .webSocket, generation: expected)
        }
    }

    private func accept(_ quote: MarkQuote, route: MainQuoteRoute, generation expected: UInt64) {
        guard generation == expected, let plan,
              plan.contracts.contains(quote.contract) else { return }
        if route == .webSocket {
            subscribedIDs.insert(quote.contract.id)
            healthyStreamingIDs.insert(quote.contract.id)
            lastStreamedAt[quote.contract.id] = Date()
            phase = healthyStreamingIDs.count == plan.contracts.count
                ? .streaming : .restFallback(attempt: 0)
        }
        guard let observation = stateBook.apply(quote, route: route) else {
            if route == .webSocket { emit() }
            return
        }
        emit(advancedQuotes: [observation])
    }

    private func accept(_ value: MainQuoteFetchResult, route: MainQuoteRoute,
                        generation expected: UInt64) {
        guard generation == expected else { return }
        if route == .restFallback, healthyStreamingIDs.contains(value.contract.id) {
            return
        }
        if let quote = value.quote,
           let observation = stateBook.apply(quote, route: route) {
            emit(advancedQuotes: [observation])
        } else if let error = value.error {
            stateBook.recordFailure(value.contract, message: error)
            emit()
        }
    }

    private func runRESTPass(contracts: [Contract], feed: any MainQuoteFeedAdapter,
                             route: MainQuoteRoute, generation expected: UInt64) async {
        var iterator = contracts.makeIterator()
        await withTaskGroup(of: MainQuoteFetchResult.self) { group in
            for _ in 0..<min(3, contracts.count) {
                guard let contract = iterator.next() else { break }
                group.addTask { await feed.fetch(contract) }
            }
            while let result = await group.next() {
                guard generation == expected, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                accept(result, route: route, generation: expected)
                if let contract = iterator.next() {
                    group.addTask { await feed.fetch(contract) }
                }
            }
        }
    }

    private func rotateRESTOrder(_ contracts: [Contract], generation expected: UInt64) -> [Contract] {
        guard generation == expected, !contracts.isEmpty else { return contracts }
        let offset = restStartOffset % contracts.count
        restStartOffset = (offset + 3) % contracts.count
        guard offset > 0 else { return contracts }
        return Array(contracts[offset...]) + Array(contracts[..<offset])
    }

    private func contractsNeedingREST(generation expected: UInt64) -> [Contract] {
        guard generation == expected, let plan else { return [] }
        guard feed?.supportsStreaming == true else { return plan.contracts }
        return plan.contracts.filter { !healthyStreamingIDs.contains($0.id) }
    }

    private func expireInactiveStreams(generation expected: UInt64, now: Date = Date()) {
        guard generation == expected, let plan, feed?.supportsStreaming == true else { return }
        let expired = plan.contracts.filter { contract in
            guard healthyStreamingIDs.contains(contract.id),
                  let last = lastStreamedAt[contract.id] else { return false }
            return now.timeIntervalSince(last) > plan.staleAfter
        }
        guard !expired.isEmpty else { return }
        for contract in expired {
            healthyStreamingIDs.remove(contract.id)
            lastStreamedAt.removeValue(forKey: contract.id)
        }
        stateBook.markGap(.disconnected, contracts: expired, now: now)
        phase = .restFallback(attempt: 0)
    }

    private func emit(advancedQuotes: [MainQuoteObservation] = []) {
        let now = Date()
        let isRecoveringConsumer = consumerGapPending
        if isRecoveringConsumer {
            stateBook.markGap(.consumerLag, now: now)
        }
        revision &+= 1
        let entries = plan.map {
            stateBook.states(for: $0.contracts, at: now, staleAfter: $0.staleAfter)
        } ?? [:]
        let result = continuation.yield(MainQuoteUpdate(
            snapshot: MainQuoteSnapshot(revision: revision, phase: phase,
                                        entries: entries, observedAt: now),
            advancedQuotes: isRecoveringConsumer ? [] : advancedQuotes
        ))
        switch result {
        case .enqueued:
            if isRecoveringConsumer { consumerGapPending = false }
        case .dropped:
            consumerGapPending = true
        case .terminated:
            break
        @unknown default:
            consumerGapPending = true
        }
    }

    private func cancelWork() async {
        streamTask?.cancel(); streamTask = nil
        restTask?.cancel(); restTask = nil
        staleTask?.cancel(); staleTask = nil
        let oldFeed = feed
        feed = nil
        await oldFeed?.cancelAll()
    }
}
