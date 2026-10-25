import Foundation

/// Reserves each rule only when its notification is about to be submitted.
/// An interrupted batch leaves later rules untouched; a rejected submission
/// restores only its own exact reservation, even after the request is invalidated.
public struct PriceAlertSubmissionBatch: Sendable {
    private struct Submission: Sendable {
        let event: AlertEvent
        let original: PriceAlert
        let triggered: PriceAlert
    }

    private let submissions: [Submission]

    public init(events: [AlertEvent], originalRules: [PriceAlert], evaluatedRules: [PriceAlert]) {
        submissions = events.compactMap { event in
            guard let original = originalRules.first(where: { $0.id == event.id }),
                  let triggered = evaluatedRules.first(where: { $0.id == event.id }) else { return nil }
            return Submission(event: event, original: original, triggered: triggered)
        }
    }

    @MainActor
    public func submit(
        isCurrent: () -> Bool,
        currentRules: () -> [PriceAlert],
        updateRules: ([PriceAlert]) -> Void,
        submitNotification: @MainActor (AlertEvent) async throws -> Void,
        didSubmit: (AlertEvent) -> Void,
        didFail: (Error, Bool) -> Void
    ) async {
        func replace(_ expected: PriceAlert, with replacement: PriceAlert) -> Bool {
            var rules = currentRules()
            guard let index = rules.firstIndex(where: { $0.id == expected.id }),
                  rules[index] == expected else { return false }
            rules[index] = replacement
            updateRules(rules)
            return true
        }

        for submission in submissions {
            guard isCurrent() else { return }
            // A user edit or a newer trigger must not be consumed by this batch.
            guard replace(submission.original, with: submission.triggered) else { continue }
            do {
                try await submitNotification(submission.event)
                if isCurrent() { didSubmit(submission.event) }
            } catch {
                // Invalidating a network request does not make a failed notification
                // successful. Restore it only if its reservation is still unchanged.
                let restored = replace(submission.triggered, with: submission.original)
                didFail(error, restored)
            }
        }
    }
}
