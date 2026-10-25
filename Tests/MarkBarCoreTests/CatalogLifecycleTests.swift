import Foundation
import XCTest
@testable import MarkBarCore

private actor ControlledCatalogLoader {
    private var pending: [Int: CheckedContinuation<[Contract], Error>] = [:]
    private(set) var calls = 0

    // Deliberately ignores cancellation until released, modelling a response
    // arriving after a caller has cancelled its request.
    func load(_ exchange: Exchange) async throws -> [Contract] {
        let index = calls
        calls += 1
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func complete(_ index: Int, with result: Result<[Contract], Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }

    func completeAll(with result: Result<[Contract], Error>) {
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(with: result) }
    }
}

@MainActor
final class CatalogLifecycleTests: XCTestCase {
    private func waitForCalls(_ expected: Int, on loader: ControlledCatalogLoader) async -> Bool {
        for _ in 0..<200 {
            if await loader.calls >= expected { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func testForceReloadBypassesCacheAndRefreshesIt() async throws {
        let loader = ControlledCatalogLoader()
        let client = MarketDataClient(catalogLoader: { try await loader.load($0) })
        let first = Task { try await client.instruments(for: .okx) }
        let firstStarted = await waitForCalls(1, on: loader)
        XCTAssertTrue(firstStarted)
        await loader.complete(0, with: .success([.btc]))
        let firstValue = try await first.value
        let cached = try await client.instruments(for: .okx)
        XCTAssertEqual(firstValue, [.btc])
        XCTAssertEqual(cached, [.btc])
        let callsBeforeRefresh = await loader.calls
        XCTAssertEqual(callsBeforeRefresh, 1)

        let refresh = Task { try await client.instruments(for: .okx, forceReload: true) }
        let refreshStarted = await waitForCalls(2, on: loader)
        XCTAssertTrue(refreshStarted)
        await loader.complete(1, with: .success([.btc, .eth]))
        let refreshed = try await refresh.value
        let newCache = try await client.instruments(for: .okx)
        XCTAssertEqual(refreshed, [.btc, .eth])
        XCTAssertEqual(newCache, [.btc, .eth])
        let totalCalls = await loader.calls
        XCTAssertEqual(totalCalls, 2)
    }

    func testConcurrentForcedRefreshesShareInFlightRequest() async throws {
        let loader = ControlledCatalogLoader()
        let client = MarketDataClient(catalogLoader: { try await loader.load($0) })
        let first = Task { try await client.instruments(for: .okx, forceReload: true) }
        let firstStarted = await waitForCalls(1, on: loader)
        XCTAssertTrue(firstStarted)
        let second = Task { try await client.instruments(for: .okx, forceReload: true) }
        // Both callers are suspended on the controlled request before it is released.
        try await Task.sleep(for: .milliseconds(30))
        let startedCalls = await loader.calls
        XCTAssertEqual(startedCalls, 1)
        await loader.completeAll(with: .success([.btc]))
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, [.btc])
        XCTAssertEqual(secondValue, [.btc])
    }

    func testCancelAllPreventsLateCacheWriteAndOldCleanupOfNewRequest() async throws {
        let loader = ControlledCatalogLoader()
        let client = MarketDataClient(catalogLoader: { try await loader.load($0) })
        let old = Task { try await client.instruments(for: .okx) }
        let oldStarted = await waitForCalls(1, on: loader)
        XCTAssertTrue(oldStarted)
        await client.cancelAll()

        let replacement = Task { try await client.instruments(for: .okx, forceReload: true) }
        let replacementStarted = await waitForCalls(2, on: loader)
        XCTAssertTrue(replacementStarted, "New callers must not join the cancelled task")
        await loader.complete(0, with: .success([.btc]))
        do {
            _ = try await old.value
            XCTFail("A response from the cancelled generation must be discarded")
        } catch is CancellationError { }

        // This caller must join the replacement, not read BTC from the late old
        // response or launch a third request after an old defer removed the slot.
        let joiner = Task { try await client.instruments(for: .okx) }
        try await Task.sleep(for: .milliseconds(30))
        let callsBeforeCompletion = await loader.calls
        XCTAssertEqual(callsBeforeCompletion, 2)
        await loader.completeAll(with: .success([.eth]))
        let replacementValue = try await replacement.value
        let joinedValue = try await joiner.value
        let cached = try await client.instruments(for: .okx)
        XCTAssertEqual(replacementValue, [.eth])
        XCTAssertEqual(joinedValue, [.eth])
        XCTAssertEqual(cached, [.eth])
    }

    func testFailedForcedRefreshDoesNotReplaceVerifiedCache() async throws {
        let loader = ControlledCatalogLoader()
        let client = MarketDataClient(catalogLoader: { try await loader.load($0) })
        let first = Task { try await client.instruments(for: .okx) }
        let firstStarted = await waitForCalls(1, on: loader)
        XCTAssertTrue(firstStarted)
        await loader.complete(0, with: .success([.btc]))
        _ = try await first.value
        let refresh = Task { try await client.instruments(for: .okx, forceReload: true) }
        let refreshStarted = await waitForCalls(2, on: loader)
        XCTAssertTrue(refreshStarted)
        await loader.complete(1, with: .failure(DirectNetworkError.timeout))
        do {
            _ = try await refresh.value
            XCTFail("Forced refresh errors must be visible")
        } catch let error as MarketProviderError {
            XCTAssertEqual(error.exchange, .okx)
        }
        let cached = try await client.instruments(for: .okx)
        XCTAssertEqual(cached, [.btc])
    }
}
