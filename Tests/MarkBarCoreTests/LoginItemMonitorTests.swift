import Foundation
import XCTest
@testable import MarkBarCore

private final class ControlledLoginItemService: LoginItemService, @unchecked Sendable {
    struct Snapshot {
        var operations: [LoginItemOperation] = []
        var completed = 0
        var active = 0
        var maximumActive = 0
        var usedMainThread = false
        var blockTimedOut = false
    }

    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let results: [LoginItemResult]
    private let blockedCalls: Set<Int>
    private var recorded = Snapshot()

    init(results: [LoginItemResult], blockedCalls: Set<Int> = []) {
        self.results = results
        self.blockedCalls = blockedCalls
    }

    func perform(_ operation: LoginItemOperation) -> LoginItemResult {
        let index = lock.withLock {
            let index = recorded.operations.count
            recorded.operations.append(operation)
            recorded.active += 1
            recorded.maximumActive = max(recorded.maximumActive, recorded.active)
            recorded.usedMainThread = recorded.usedMainThread || Thread.isMainThread
            return index
        }
        let timedOut = blockedCalls.contains(index) && gate.wait(timeout: .now() + 3) == .timedOut
        return lock.withLock {
            recorded.active -= 1
            recorded.completed += 1
            recorded.blockTimedOut = recorded.blockTimedOut || timedOut
            return results[min(index, results.count - 1)]
        }
    }

    var snapshot: Snapshot { lock.withLock { recorded } }
    func release() { gate.signal() }
}

private final class LoginItemTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 100
    func read() -> TimeInterval { lock.withLock { current } }
    func set(_ value: TimeInterval) { lock.withLock { current = value } }
}

@MainActor
final class LoginItemMonitorTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Login item work did not reach the expected state", file: file, line: line)
    }

    func testBlockedSystemReadLeavesMainActorAndCachedStateAvailable() async {
        let service = ControlledLoginItemService(results: [.init(status: .enabled), .init(status: .notRegistered)],
                                                 blockedCalls: [1])
        let monitor = LoginItemMonitor(service: service)
        defer { service.release(); monitor.stop() }
        XCTAssertTrue(monitor.refreshIfNeeded(now: 0))
        await waitUntil { !monitor.isBusy }
        XCTAssertEqual(monitor.status, .enabled)

        XCTAssertTrue(monitor.refreshIfNeeded(now: 1, force: true))
        await waitUntil { service.snapshot.operations.count == 2 }
        let cachedRead = Task { @MainActor in monitor.state }
        let state = await cachedRead.value
        XCTAssertEqual(state.status, .enabled)
        XCTAssertTrue(state.isBusy)
        XCTAssertEqual(service.snapshot.completed, 1, "The main actor executed before the blocked OS read returned")
        XCTAssertFalse(service.snapshot.usedMainThread)
        XCTAssertFalse(service.snapshot.blockTimedOut)

        service.release()
        await waitUntil { !monitor.isBusy }
        XCTAssertEqual(monitor.status, .notRegistered)
    }

    func testHundredsOfRefreshesShareOneInFlightReadWithoutQueuedFollowUp() async {
        let service = ControlledLoginItemService(results: [.init(status: .enabled)], blockedCalls: [0])
        let monitor = LoginItemMonitor(service: service)
        defer { service.release(); monitor.stop() }
        XCTAssertTrue(monitor.refreshIfNeeded(now: 0))
        await waitUntil { service.snapshot.operations.count == 1 }
        for index in 1...500 {
            XCTAssertFalse(monitor.refreshIfNeeded(now: Double(index), force: index.isMultiple(of: 2)))
        }
        XCTAssertEqual(service.snapshot.operations, [.status])
        service.release()
        await waitUntil { !monitor.isBusy }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(service.snapshot.operations, [.status])
        XCTAssertEqual(service.snapshot.maximumActive, 1)
    }

    func testDefaultTTLUsesInjectedMonotonicClockAndForceCanBypassIt() async {
        let service = ControlledLoginItemService(results: [.init(status: .enabled)])
        let clock = LoginItemTestClock()
        let monitor = LoginItemMonitor(service: service, clock: { clock.read() })
        defer { monitor.stop() }
        XCTAssertTrue(monitor.refreshIfNeeded())
        await waitUntil { !monitor.isBusy }
        clock.set(129.999)
        XCTAssertFalse(monitor.refreshIfNeeded())
        clock.set(130)
        XCTAssertTrue(monitor.refreshIfNeeded())
        await waitUntil { !monitor.isBusy }
        XCTAssertTrue(monitor.refreshIfNeeded(now: 131, force: true))
        await waitUntil { !monitor.isBusy }
        XCTAssertFalse(monitor.refreshIfNeeded(now: 160.999))
        XCTAssertTrue(monitor.refreshIfNeeded(now: 161))
        await waitUntil { !monitor.isBusy }
        XCTAssertEqual(service.snapshot.operations, [.status, .status, .status, .status])
    }

    func testMutationsAndQueriesStaySerialAndBusyCommandsAreRejected() async {
        let service = ControlledLoginItemService(results: [.init(status: .notRegistered),
                                                           .init(status: .enabled),
                                                           .init(status: .notRegistered)],
                                                 blockedCalls: [0, 1, 2])
        let monitor = LoginItemMonitor(service: service)
        defer { service.release(); monitor.stop() }
        XCTAssertTrue(monitor.refreshIfNeeded(now: 0))
        await waitUntil { service.snapshot.operations.count == 1 }
        XCTAssertFalse(monitor.request(operation: .registerIfNeeded, now: 1))
        XCTAssertFalse(monitor.request(operation: .toggle, now: 1))
        service.release()
        await waitUntil { !monitor.isBusy }

        XCTAssertTrue(monitor.request(operation: .registerIfNeeded, now: 2))
        await waitUntil { service.snapshot.operations.count == 2 }
        XCTAssertFalse(monitor.refreshIfNeeded(now: 100, force: true))
        XCTAssertFalse(monitor.request(operation: .toggle, now: 100))
        service.release()
        await waitUntil { !monitor.isBusy }
        XCTAssertEqual(monitor.status, .enabled)

        XCTAssertTrue(monitor.request(operation: .toggle, now: 3))
        await waitUntil { service.snapshot.operations.count == 3 }
        XCTAssertFalse(monitor.request(operation: .toggle, now: 3))
        service.release()
        await waitUntil { !monitor.isBusy }
        XCTAssertEqual(service.snapshot.operations, [.status, .registerIfNeeded, .toggle])
        XCTAssertEqual(service.snapshot.maximumActive, 1)
        XCTAssertFalse(service.snapshot.usedMainThread)
        XCTAssertEqual(monitor.status, .notRegistered)
    }

    func testStatusPollingPreservesMutationErrorUntilNextExplicitCommand() async {
        let service = ControlledLoginItemService(results: [
            .init(status: .notRegistered, error: "Registration denied"),
            .init(status: .notRegistered),
            .init(status: .requiresApproval),
        ], blockedCalls: [2])
        let monitor = LoginItemMonitor(service: service)
        defer { service.release(); monitor.stop() }
        XCTAssertTrue(monitor.request(operation: .registerIfNeeded, now: 0))
        await waitUntil { !monitor.isBusy }
        XCTAssertEqual(monitor.error, "Registration denied")
        XCTAssertTrue(monitor.refreshIfNeeded(now: 30))
        XCTAssertEqual(monitor.error, "Registration denied")
        await waitUntil { !monitor.isBusy }
        XCTAssertEqual(monitor.error, "Registration denied")

        XCTAssertTrue(monitor.request(operation: .toggle, now: 31))
        XCTAssertNil(monitor.error)
        service.release()
        await waitUntil { !monitor.isBusy }
        XCTAssertNil(monitor.error)
        XCTAssertEqual(monitor.status, .requiresApproval)
    }

    func testStopRejectsNewWorkDisconnectsCallbackAndDiscardsLateResult() async {
        let service = ControlledLoginItemService(results: [.init(status: .enabled)], blockedCalls: [0])
        let monitor = LoginItemMonitor(service: service)
        defer { service.release() }
        var changes: [LoginItemState] = []
        monitor.onChange = { changes.append(monitor.state) }
        XCTAssertTrue(monitor.refreshIfNeeded(now: 0))
        await waitUntil { service.snapshot.operations.count == 1 }
        XCTAssertEqual(changes.count, 1)
        monitor.stop()
        let stoppedState = monitor.state
        XCTAssertFalse(stoppedState.isBusy)
        XCTAssertNil(monitor.onChange)
        XCTAssertFalse(monitor.refreshIfNeeded(now: 100, force: true))
        XCTAssertFalse(monitor.request(operation: .toggle, now: 100))
        service.release()
        await waitUntil { service.snapshot.completed == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(monitor.state, stoppedState)
        XCTAssertEqual(monitor.status, .unknown)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(service.snapshot.operations, [.status])
    }
}
