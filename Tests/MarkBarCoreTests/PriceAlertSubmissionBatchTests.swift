import Foundation
import XCTest
@testable import MarkBarCore

@MainActor
private final class ControlledAlertNotifications {
    enum Rejection: Error { case denied }
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private(set) var calls: [UUID] = []

    // Cancellation deliberately does not resume this call: the OS can reply late.
    func submit(_ event: AlertEvent) async throws {
        let index = calls.count
        calls.append(event.id)
        try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func finish(_ index: Int, with result: Result<Void, Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }
}

@MainActor
private final class AlertSubmissionState {
    var rules: [PriceAlert]
    var generation = 0
    var completed: [UUID] = []
    var restoredFailures: [Bool] = []

    init(rules: [PriceAlert]) { self.rules = rules }

    func submit(_ batch: PriceAlertSubmissionBatch, generation expected: Int,
                notifications: ControlledAlertNotifications) async {
        await batch.submit(
            isCurrent: { self.generation == expected && !Task.isCancelled },
            currentRules: { self.rules },
            updateRules: { self.rules = $0 },
            submitNotification: { try await notifications.submit($0) },
            didSubmit: { self.completed.append($0.id) },
            didFail: { _, restored in self.restoredFailures.append(restored) }
        )
    }
}

@MainActor
final class PriceAlertSubmissionBatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func quote(_ price: Decimal, at seconds: TimeInterval) -> MarkQuote {
        let time = start.addingTimeInterval(seconds)
        return MarkQuote(contract: .btc, price: price, dataTime: time, receivedAt: time)
    }

    private func batch(_ rules: [PriceAlert], at seconds: TimeInterval = 1) -> PriceAlertSubmissionBatch {
        var engine = PriceAlertEngine()
        var evaluated = rules
        _ = engine.evaluate(quote(99, at: seconds - 1), rules: &evaluated, now: start.addingTimeInterval(seconds - 1))
        let events = engine.evaluate(quote(101, at: seconds), rules: &evaluated, now: start.addingTimeInterval(seconds))
        return PriceAlertSubmissionBatch(events: events, originalRules: rules, evaluatedRules: evaluated)
    }

    private func waitForCalls(_ count: Int, on notifications: ControlledAlertNotifications) async {
        for _ in 0..<200 {
            if notifications.calls.count >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Notification submission did not reach the controlled suspension")
    }

    func testNetworkInvalidationLeavesUnsubmittedCrossingArmed() async {
        let rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100),
                     PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        let state = AlertSubmissionState(rules: rules)
        let notifications = ControlledAlertNotifications()
        let pending = Task { await state.submit(batch(rules), generation: 0, notifications: notifications) }
        await waitForCalls(1, on: notifications)
        XCTAssertFalse(state.rules[0].isEnabled)
        XCTAssertEqual(state.rules[1], rules[1], "A queued event has not reserved its rule")

        state.generation += 1
        var newNetworkEngine = PriceAlertEngine()
        var newNetworkRules = state.rules
        XCTAssertTrue(newNetworkEngine.evaluate(quote(101, at: 2), rules: &newNetworkRules,
                                               now: start.addingTimeInterval(2)).isEmpty)
        XCTAssertTrue(newNetworkRules[1].isEnabled, "The new network establishes a crossing baseline")
        notifications.finish(0, with: .success(()))
        await pending.value
        XCTAssertEqual(notifications.calls, [rules[0].id])
        XCTAssertEqual(state.rules[1], rules[1])
        XCTAssertTrue(state.completed.isEmpty, "The invalidated request cannot publish success UI")

        _ = newNetworkEngine.evaluate(quote(99, at: 3), rules: &newNetworkRules, now: start.addingTimeInterval(3))
        let newEvents = newNetworkEngine.evaluate(quote(100, at: 4), rules: &newNetworkRules,
                                                 now: start.addingTimeInterval(4))
        XCTAssertEqual(newEvents.map(\.id), [rules[1].id])
    }

    func testFailedSubmissionRestoresItsRuleAfterNetworkInvalidationAndCancellation() async {
        let rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100),
                     PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        let state = AlertSubmissionState(rules: rules)
        let notifications = ControlledAlertNotifications()
        let pending = Task { await state.submit(batch(rules), generation: 0, notifications: notifications) }
        await waitForCalls(1, on: notifications)
        state.generation += 1
        pending.cancel()
        notifications.finish(0, with: .failure(ControlledAlertNotifications.Rejection.denied))
        await pending.value
        XCTAssertEqual(state.rules, rules)
        XCTAssertEqual(notifications.calls, [rules[0].id])
        XCTAssertEqual(state.restoredFailures, [true])
    }

    func testFailedSubmissionDoesNotOverwriteUserEdit() async {
        let rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        let state = AlertSubmissionState(rules: rules)
        let notifications = ControlledAlertNotifications()
        let pending = Task { await state.submit(batch(rules), generation: 0, notifications: notifications) }
        await waitForCalls(1, on: notifications)
        var edited = rules[0]
        edited.threshold = 200
        state.rules[0] = edited
        notifications.finish(0, with: .failure(ControlledAlertNotifications.Rejection.denied))
        await pending.value
        XCTAssertEqual(state.rules, [edited])
        XCTAssertEqual(state.restoredFailures, [false])
    }

    func testFailedOlderSubmissionDoesNotOverwriteNewerTrigger() async {
        let rules = [PriceAlert(contract: .btc, direction: .greaterThan, threshold: 100,
                               repeats: true, cooldown: 0)]
        let state = AlertSubmissionState(rules: rules)
        let notifications = ControlledAlertNotifications()
        let old = Task { await state.submit(batch(rules), generation: 0, notifications: notifications) }
        await waitForCalls(1, on: notifications)
        let newerBatch = batch(state.rules, at: 3)
        let newer = Task { await state.submit(newerBatch, generation: 0, notifications: notifications) }
        await waitForCalls(2, on: notifications)
        notifications.finish(1, with: .success(()))
        await newer.value
        let newerRules = state.rules
        XCTAssertEqual(newerRules[0].lastTriggeredAt, start.addingTimeInterval(3))
        notifications.finish(0, with: .failure(ControlledAlertNotifications.Rejection.denied))
        await old.value
        XCTAssertEqual(state.rules, newerRules)
        XCTAssertEqual(state.restoredFailures, [false])
    }

    func testQueuedRuleEditedDuringEarlierSubmissionIsNotConsumed() async {
        let rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100),
                     PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        let state = AlertSubmissionState(rules: rules)
        let notifications = ControlledAlertNotifications()
        let pending = Task { await state.submit(batch(rules), generation: 0, notifications: notifications) }
        await waitForCalls(1, on: notifications)
        var edited = rules[1]
        edited.threshold = 200
        state.rules[1] = edited
        notifications.finish(0, with: .success(()))
        await pending.value
        XCTAssertEqual(notifications.calls, [rules[0].id])
        XCTAssertEqual(state.rules[1], edited)
        XCTAssertEqual(state.completed, [rules[0].id])
    }
}
