import XCTest
@testable import MarkBarCore

private actor ScriptedMainQuoteFeed: MainQuoteFeedAdapter {
    nonisolated let supportsStreaming: Bool
    private let fetchResults: [MainQuoteFetchResult]
    private let streamEvents: [MainQuoteStreamEvent]
    private var fetchedContracts: [[Contract]] = []

    init(supportsStreaming: Bool, fetchResults: [MainQuoteFetchResult],
         streamEvents: [MainQuoteStreamEvent] = []) {
        self.supportsStreaming = supportsStreaming
        self.fetchResults = fetchResults
        self.streamEvents = streamEvents
    }

    func stream(contracts: [Contract]) async -> AsyncThrowingStream<MainQuoteStreamEvent, Error> {
        let events = streamEvents
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
        }
    }

    func fetch(_ contract: Contract) async -> MainQuoteFetchResult {
        fetchedContracts.append([contract])
        return fetchResults.first { $0.contract == contract }
            ?? MainQuoteFetchResult(contract: contract, quote: nil, error: "missing fixture")
    }
    func fetchHistory() -> [[Contract]] { fetchedContracts }
    func cancelAll() async {}
}

private struct ScriptedMainQuoteFactory: MainQuoteFeedFactory {
    let feed: any MainQuoteFeedAdapter
    func make(exchange: Exchange, networkMode: NetworkMode) -> any MainQuoteFeedAdapter { feed }
}

private actor DelayedMainQuoteFeed: MainQuoteFeedAdapter {
    nonisolated let supportsStreaming = false
    private let delays: [String: UInt64]
    private var activeFetches = 0
    private var peakFetches = 0

    init(delays: [String: UInt64]) { self.delays = delays }

    func stream(contracts: [Contract]) async -> AsyncThrowingStream<MainQuoteStreamEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    func fetch(_ contract: Contract) async -> MainQuoteFetchResult {
        activeFetches += 1
        peakFetches = max(peakFetches, activeFetches)
        try? await Task.sleep(nanoseconds: delays[contract.id] ?? 0)
        activeFetches -= 1
        let now = Date()
        return MainQuoteFetchResult(
            contract: contract,
            quote: MarkQuote(contract: contract, price: 1, dataTime: now, receivedAt: now),
            error: nil
        )
    }

    func cancelAll() async {}
    func peakConcurrency() -> Int { peakFetches }
}

private actor FinishingMainQuoteFeed: MainQuoteFeedAdapter {
    nonisolated let supportsStreaming = true
    private var streamCount = 0

    func stream(contracts: [Contract]) async -> AsyncThrowingStream<MainQuoteStreamEvent, Error> {
        streamCount += 1
        return AsyncThrowingStream { continuation in continuation.finish() }
    }

    func fetch(_ contract: Contract) async -> MainQuoteFetchResult {
        MainQuoteFetchResult(contract: contract, quote: nil, error: "offline")
    }

    func cancelAll() async {}
    func openedStreamCount() -> Int { streamCount }
}

final class MainQuoteSessionTests: XCTestCase {
    func testRESTOnlyPlanPublishesSampledQuoteAndPossibleMissedState() async throws {
        let now = Date()
        let quote = MarkQuote(contract: .btc, price: 80_000,
                              dataTime: now, receivedAt: now)
        let feed = ScriptedMainQuoteFeed(supportsStreaming: false, fetchResults: [
            MainQuoteFetchResult(contract: .btc, quote: quote, error: nil),
        ])
        let session = MainQuoteSession(factory: ScriptedMainQuoteFactory(feed: feed))
        let updates = await session.updates()
        let result = Task { () -> MainQuoteUpdate? in
            for await update in updates where !update.advancedQuotes.isEmpty { return update }
            return nil
        }

        try await session.reconcile(MainQuotePlan(exchange: .okx, networkMode: .physicalDirect,
                                                   contracts: [.btc], restInterval: 5,
                                                   staleAfter: 20))
        let update = await result.value
        XCTAssertEqual(update?.advancedQuotes.first?.quote.price, 80_000)
        XCTAssertEqual(update?.advancedQuotes.first?.route, .restOnly)
        XCTAssertTrue(update?.snapshot.state(for: .btc)?.possiblyMissed == true)
        await session.stop()
    }

    func testRejectsMoreThanTwentyContractsThroughSessionInterface() async {
        let contracts = (0..<21).map {
            Contract(exchange: .okx, instrumentID: "COIN\($0)-USDT-SWAP", symbol: "COIN\($0)")
        }
        let feed = ScriptedMainQuoteFeed(supportsStreaming: false, fetchResults: [])
        let session = MainQuoteSession(factory: ScriptedMainQuoteFactory(feed: feed))
        do {
            try await session.reconcile(MainQuotePlan(exchange: .okx, networkMode: .physicalDirect,
                                                       contracts: contracts, restInterval: 5,
                                                       staleAfter: 20))
            XCTFail("Expected validation failure")
        } catch let error as MainQuoteSessionError {
            guard case .tooManyContracts = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRESTFallbackOnlyPollsContractWithoutHealthyStream() async throws {
        let now = Date()
        let btcQuote = MarkQuote(contract: .btc, price: 80_000,
                                 dataTime: now, receivedAt: now)
        let ethQuote = MarkQuote(contract: .eth, price: 4_000,
                                 dataTime: now, receivedAt: now)
        let feed = ScriptedMainQuoteFeed(
            supportsStreaming: true,
            fetchResults: [MainQuoteFetchResult(contract: .btc, quote: btcQuote, error: nil),
                           MainQuoteFetchResult(contract: .eth, quote: ethQuote, error: nil)],
            streamEvents: [.subscribed(.btc), .quote(btcQuote),
                           .subscriptionFailed(.eth, "subscription rejected")]
        )
        let session = MainQuoteSession(factory: ScriptedMainQuoteFactory(feed: feed))

        try await session.reconcile(MainQuotePlan(exchange: .okx, networkMode: .system,
                                                   contracts: [.btc, .eth], restInterval: 0.03,
                                                   staleAfter: 20))
        try await Task.sleep(nanoseconds: 180_000_000)

        let history = await feed.fetchHistory()
        XCTAssertTrue(history.contains([.eth]))
        XCTAssertEqual(history.last, [.eth])
        await session.stop()
    }

    func testRESTWorkerPoolPublishesCompletedResultWithoutWaitingForBatch() async throws {
        let contracts = (0..<4).map {
            Contract(exchange: .okx, instrumentID: "COIN\($0)-USDT-SWAP", symbol: "COIN\($0)")
        }
        let feed = DelayedMainQuoteFeed(delays: [
            contracts[0].id: 600_000_000,
            contracts[1].id: 20_000_000,
            contracts[2].id: 600_000_000,
            contracts[3].id: 20_000_000,
        ])
        let session = MainQuoteSession(factory: ScriptedMainQuoteFactory(feed: feed))
        let updates = await session.updates()

        let first = Task { () -> MainQuoteObservation? in
            for await update in updates {
                if let observation = update.advancedQuotes.first { return observation }
            }
            return nil
        }
        try await session.reconcile(MainQuotePlan(exchange: .okx, networkMode: .physicalDirect,
                                                   contracts: contracts, restInterval: 10,
                                                   staleAfter: 20))

        let observation = try await withThrowingTaskGroup(of: MainQuoteObservation?.self) { group in
            group.addTask { await first.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 300_000_000)
                return nil
            }
            let value = try await group.next() ?? nil
            group.cancelAll()
            return value
        }

        XCTAssertEqual(observation?.quote.contract, contracts[1])
        let peakConcurrency = await feed.peakConcurrency()
        XCTAssertEqual(peakConcurrency, 3)
        await session.stop()
    }

    func testConsumerBackpressureBecomesExplicitContinuityGap() async throws {
        let base = Date()
        let events: [MainQuoteStreamEvent] = (0..<100).map { index in
            .quote(MarkQuote(contract: .btc, price: Decimal(80_000 + index),
                             dataTime: base.addingTimeInterval(Double(index) / 1_000),
                             receivedAt: base))
        }
        let feed = ScriptedMainQuoteFeed(supportsStreaming: true, fetchResults: [],
                                         streamEvents: events)
        let session = MainQuoteSession(factory: ScriptedMainQuoteFactory(feed: feed))
        try await session.reconcile(MainQuotePlan(exchange: .okx, networkMode: .system,
                                                   contracts: [.btc], restInterval: 10,
                                                   staleAfter: 20))
        try await Task.sleep(nanoseconds: 120_000_000)
        let updates = await session.updates()

        let foundGap = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await update in updates {
                    guard let state = update.snapshot.state(for: .btc) else { continue }
                    if case .possiblyMissed(_, .consumerLag) = state.continuity { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let value = await group.next() ?? false
            group.cancelAll()
            return value
        }

        XCTAssertTrue(foundGap)
        await session.stop()
    }

    func testUnexpectedStreamCompletionReconnects() async throws {
        let feed = FinishingMainQuoteFeed()
        let session = MainQuoteSession(factory: ScriptedMainQuoteFactory(feed: feed))

        try await session.reconcile(MainQuotePlan(exchange: .okx, networkMode: .system,
                                                   contracts: [.btc], restInterval: 10,
                                                   staleAfter: 20))
        try await Task.sleep(nanoseconds: 1_300_000_000)

        let openedStreamCount = await feed.openedStreamCount()
        XCTAssertGreaterThanOrEqual(openedStreamCount, 2)
        await session.stop()
    }
}
