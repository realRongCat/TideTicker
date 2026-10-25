import Foundation
import XCTest
@testable import MarkBarCore

final class PriceAlertTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func quote(_ price: Decimal, at seconds: TimeInterval, contract: Contract = .btc) -> MarkQuote {
        let time = start.addingTimeInterval(seconds)
        return MarkQuote(contract: contract, price: price, dataTime: time, receivedAt: time)
    }

    private func evaluate(_ price: Decimal, at seconds: TimeInterval, engine: inout PriceAlertEngine,
                          rules: inout [PriceAlert], staleAfter: TimeInterval = 20) -> [AlertEvent] {
        engine.evaluate(quote(price, at: seconds), rules: &rules,
                        now: start.addingTimeInterval(seconds), staleAfter: staleAfter)
    }

    func testSimpleTemplatesMapToExistingDirectionalCrossingSemantics() {
        XCTAssertEqual(SimpleAlertTemplate.risesTo.direction, .above)
        XCTAssertEqual(SimpleAlertTemplate.fallsTo.direction, .below)

        for (template, baseline, threshold, beyond) in [
            (SimpleAlertTemplate.risesTo, Decimal(99), Decimal(100), Decimal(101)),
            (.fallsTo, Decimal(101), Decimal(100), Decimal(99)),
        ] {
            var engine = PriceAlertEngine()
            var rules = [PriceAlert(contract: .btc, direction: template.direction,
                                    threshold: threshold, repeats: true, cooldown: 0)]
            XCTAssertTrue(evaluate(beyond, at: 0, engine: &engine, rules: &rules).isEmpty)
            XCTAssertTrue(evaluate(baseline, at: 1, engine: &engine, rules: &rules).isEmpty)
            XCTAssertEqual(evaluate(threshold, at: 2, engine: &engine, rules: &rules).count, 1)
            XCTAssertTrue(evaluate(beyond, at: 3, engine: &engine, rules: &rules).isEmpty)
            XCTAssertTrue(evaluate(beyond, at: 30, engine: &engine, rules: &rules).isEmpty)
            XCTAssertTrue(evaluate(baseline, at: 31, engine: &engine, rules: &rules).isEmpty)
            XCTAssertEqual(evaluate(threshold, at: 32, engine: &engine, rules: &rules).count, 1)
        }
    }

    func testFirstQuoteSetsBaselineAndUpwardCrossingTriggersOnReachingThreshold() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        XCTAssertTrue(evaluate(101, at: 0, engine: &engine, rules: &rules).isEmpty)
        XCTAssertTrue(evaluate(99, at: 1, engine: &engine, rules: &rules).isEmpty)
        let events = evaluate(100, at: 2, engine: &engine, rules: &rules)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.id, rules[0].id)
        XCTAssertEqual(events.first?.price, 100)
        XCTAssertEqual(events.first?.time, start.addingTimeInterval(2))
        XCTAssertFalse(rules[0].isEnabled)
        XCTAssertEqual(rules[0].lastTriggeredAt, start.addingTimeInterval(2))
        XCTAssertTrue(evaluate(101, at: 3, engine: &engine, rules: &rules).isEmpty)
    }

    func testBelowCrossingUsesTheOppositeBoundary() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .below, threshold: 100)]
        XCTAssertTrue(evaluate(101, at: 0, engine: &engine, rules: &rules).isEmpty)
        XCTAssertEqual(evaluate(100, at: 1, engine: &engine, rules: &rules).count, 1)
        XCTAssertTrue(evaluate(99, at: 2, engine: &engine, rules: &rules).isEmpty)
    }

    func testDirectionalCrossingsDoNotInferDirectionFromEqualityOrRepeatAtTheBoundary() {
        for (direction, origin, beyond) in [(AlertDirection.above, 99, 101), (.below, 101, 99)] {
            var engine = PriceAlertEngine()
            var rules = [PriceAlert(contract: .btc, direction: direction, threshold: 100, repeats: true, cooldown: 0)]
            XCTAssertTrue(evaluate(100, at: 0, engine: &engine, rules: &rules).isEmpty)
            XCTAssertTrue(evaluate(Decimal(beyond), at: 1, engine: &engine, rules: &rules).isEmpty)
            XCTAssertTrue(evaluate(Decimal(origin), at: 2, engine: &engine, rules: &rules).isEmpty)
            XCTAssertEqual(evaluate(100, at: 3, engine: &engine, rules: &rules).count, 1)
            XCTAssertTrue(evaluate(100, at: 4, engine: &engine, rules: &rules).isEmpty)
            XCTAssertTrue(evaluate(Decimal(beyond), at: 5, engine: &engine, rules: &rules).isEmpty)
            XCTAssertTrue(evaluate(100, at: 6, engine: &engine, rules: &rules).isEmpty)
            XCTAssertTrue(evaluate(Decimal(origin), at: 7, engine: &engine, rules: &rules).isEmpty)
            XCTAssertEqual(evaluate(100, at: 8, engine: &engine, rules: &rules).count, 1)
        }
    }

    func testBidirectionalCrossingReachesOrSkipsThresholdFromEitherSide() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .crossing, threshold: 100, repeats: true, cooldown: 0)]
        XCTAssertTrue(evaluate(100, at: 0, engine: &engine, rules: &rules).isEmpty)
        XCTAssertTrue(evaluate(101, at: 1, engine: &engine, rules: &rules).isEmpty)
        XCTAssertEqual(evaluate(100, at: 2, engine: &engine, rules: &rules).count, 1)
        XCTAssertTrue(evaluate(100, at: 3, engine: &engine, rules: &rules).isEmpty)
        XCTAssertTrue(evaluate(99, at: 4, engine: &engine, rules: &rules).isEmpty)
        XCTAssertEqual(evaluate(100, at: 5, engine: &engine, rules: &rules).count, 1)
        XCTAssertTrue(evaluate(101, at: 6, engine: &engine, rules: &rules).isEmpty)
        XCTAssertEqual(evaluate(99, at: 7, engine: &engine, rules: &rules).count, 1)
        XCTAssertEqual(evaluate(101, at: 8, engine: &engine, rules: &rules).count, 1)
    }

    func testCurrentValueConditionsAreStrictAndCanTriggerOnTheFirstFreshQuote() {
        for (direction, matching, otherSide) in [(AlertDirection.greaterThan, 101, 99), (.lessThan, 99, 101)] {
            var engine = PriceAlertEngine()
            var rules = [PriceAlert(contract: .btc, direction: direction, threshold: 100, repeats: true, cooldown: 0)]
            XCTAssertEqual(evaluate(Decimal(matching), at: 0, engine: &engine, rules: &rules).count, 1)
            XCTAssertTrue(evaluate(100, at: 1, engine: &engine, rules: &rules).isEmpty)
            XCTAssertTrue(evaluate(Decimal(otherSide), at: 2, engine: &engine, rules: &rules).isEmpty)
            XCTAssertEqual(evaluate(Decimal(matching), at: 3, engine: &engine, rules: &rules).count, 1)
        }
    }

    func testSingleUseCurrentValueConditionDisablesAfterItsFirstMatch() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .greaterThan, threshold: 100)]
        XCTAssertEqual(evaluate(101, at: 0, engine: &engine, rules: &rules).count, 1)
        XCTAssertFalse(rules[0].isEnabled)
        XCTAssertEqual(rules[0].lastTriggeredAt, start)
        XCTAssertTrue(evaluate(102, at: 1, engine: &engine, rules: &rules).isEmpty)
    }

    func testSustainedCurrentValueConditionsRepeatAtTheDefaultOneMinuteInterval() {
        for (direction, price) in [(AlertDirection.greaterThan, 101), (.lessThan, 99)] {
            var engine = PriceAlertEngine()
            var rules = [PriceAlert(contract: .btc, direction: direction, threshold: 100, repeats: true)]
            XCTAssertEqual(rules[0].cooldown, 60)
            XCTAssertEqual(evaluate(Decimal(price), at: 0, engine: &engine, rules: &rules).count, 1)
            for second in [10, 20, 30, 40, 50, 59] {
                XCTAssertTrue(evaluate(Decimal(price), at: TimeInterval(second), engine: &engine, rules: &rules).isEmpty)
            }
            XCTAssertEqual(evaluate(Decimal(price), at: 60, engine: &engine, rules: &rules).count, 1)
            XCTAssertTrue(rules[0].isEnabled)
            XCTAssertEqual(rules[0].lastTriggeredAt, start.addingTimeInterval(60))
        }
    }

    func testCurrentValueConditionRejectsInvalidSnapshotsAndMatchesFreshRecovery() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .greaterThan, threshold: 100, repeats: true, cooldown: 0)]
        XCTAssertEqual(evaluate(101, at: 0, engine: &engine, rules: &rules).count, 1)
        XCTAssertTrue(engine.evaluate(quote(102, at: 0), rules: &rules, now: start.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(engine.evaluate(quote(102, at: -1), rules: &rules, now: start.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(evaluate(.nan, at: 1, engine: &engine, rules: &rules).isEmpty)
        XCTAssertTrue(evaluate(0, at: 2, engine: &engine, rules: &rules).isEmpty)
        XCTAssertTrue(engine.evaluate(quote(102, at: 100), rules: &rules, now: start.addingTimeInterval(3)).isEmpty)
        XCTAssertTrue(engine.evaluate(quote(102, at: 4), rules: &rules, now: start.addingTimeInterval(30)).isEmpty)
        XCTAssertEqual(rules[0].lastTriggeredAt, start)
        XCTAssertEqual(evaluate(102, at: 31, engine: &engine, rules: &rules).count, 1)
        // A gap with no intermediate stale response also permits a current-value match.
        XCTAssertEqual(evaluate(102, at: 60, engine: &engine, rules: &rules).count, 1)
    }

    func testMultipleRulesAndContractsKeepIndependentTriggerTimes() {
        var engine = PriceAlertEngine()
        var rules = [
            PriceAlert(contract: .btc, direction: .greaterThan, threshold: 100, repeats: true, cooldown: 60),
            PriceAlert(contract: .btc, direction: .greaterThan, threshold: 100, repeats: true, cooldown: 10),
            PriceAlert(contract: .eth, direction: .lessThan, threshold: 200, repeats: true, cooldown: 60),
        ]
        let ids = rules.map(\.id)
        XCTAssertEqual(evaluate(101, at: 0, engine: &engine, rules: &rules).map(\.id), Array(ids.prefix(2)))
        XCTAssertNil(rules[2].lastTriggeredAt)
        XCTAssertEqual(evaluate(101, at: 30, engine: &engine, rules: &rules).map(\.id), [ids[1]])
        let ethEvents = engine.evaluate(quote(199, at: 30, contract: .eth), rules: &rules, now: start.addingTimeInterval(30))
        XCTAssertEqual(ethEvents.map(\.id), [ids[2]])
        XCTAssertEqual(evaluate(101, at: 60, engine: &engine, rules: &rules).map(\.id), Array(ids.prefix(2)))
        XCTAssertEqual(rules[2].lastTriggeredAt, start.addingTimeInterval(30))
    }

    func testDuplicateRuleIDsCannotProduceTwoEvents() {
        var engine = PriceAlertEngine()
        let rule = PriceAlert(contract: .btc, direction: .greaterThan, threshold: 100, repeats: true, cooldown: 0)
        var rules = [rule, rule]
        XCTAssertEqual(evaluate(101, at: 0, engine: &engine, rules: &rules).map(\.id), [rule.id])
    }

    func testDuplicateAndOutOfOrderQuotesCannotMoveTheBaseline() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        _ = evaluate(99, at: 10, engine: &engine, rules: &rules)
        XCTAssertTrue(engine.evaluate(quote(101, at: 10), rules: &rules, now: start.addingTimeInterval(11)).isEmpty)
        XCTAssertTrue(engine.evaluate(quote(101, at: 9), rules: &rules, now: start.addingTimeInterval(11)).isEmpty)
        XCTAssertEqual(evaluate(101, at: 12, engine: &engine, rules: &rules).count, 1)
    }

    func testStaleResponseAndFreshRecoveryDoNotInventCrossings() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        _ = evaluate(99, at: 0, engine: &engine, rules: &rules)
        XCTAssertTrue(engine.evaluate(quote(101, at: 1), rules: &rules, now: start.addingTimeInterval(30)).isEmpty)
        XCTAssertTrue(evaluate(101, at: 31, engine: &engine, rules: &rules).isEmpty)
        _ = evaluate(99, at: 35, engine: &engine, rules: &rules)
        XCTAssertEqual(evaluate(101, at: 40, engine: &engine, rules: &rules).count, 1)
    }

    func testSilentGapAlsoResetsCrossingBaseline() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        _ = evaluate(99, at: 0, engine: &engine, rules: &rules)
        XCTAssertTrue(evaluate(101, at: 25, engine: &engine, rules: &rules).isEmpty)
        _ = evaluate(99, at: 26, engine: &engine, rules: &rules)
        XCTAssertEqual(evaluate(101, at: 27, engine: &engine, rules: &rules).count, 1)
    }

    func testRepeatingAlertRequiresRecrossingAndDoesNotQueueCooldownCrossing() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100, repeats: true, cooldown: 30)]
        _ = evaluate(99, at: 0, engine: &engine, rules: &rules, staleAfter: 60)
        XCTAssertEqual(evaluate(101, at: 1, engine: &engine, rules: &rules, staleAfter: 60).count, 1)
        _ = evaluate(99, at: 2, engine: &engine, rules: &rules, staleAfter: 60)
        XCTAssertTrue(evaluate(101, at: 3, engine: &engine, rules: &rules, staleAfter: 60).isEmpty)
        XCTAssertTrue(evaluate(102, at: 32, engine: &engine, rules: &rules, staleAfter: 60).isEmpty)
        _ = evaluate(99, at: 33, engine: &engine, rules: &rules, staleAfter: 60)
        XCTAssertEqual(evaluate(101, at: 34, engine: &engine, rules: &rules, staleAfter: 60).count, 1)
        XCTAssertTrue(rules[0].isEnabled)
    }

    func testThresholdEditStartsANewBaseline() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        _ = evaluate(99, at: 0, engine: &engine, rules: &rules)
        rules[0].threshold = 90
        XCTAssertTrue(evaluate(101, at: 1, engine: &engine, rules: &rules).isEmpty)
        _ = evaluate(89, at: 2, engine: &engine, rules: &rules)
        XCTAssertEqual(evaluate(91, at: 3, engine: &engine, rules: &rules).count, 1)
    }

    func testReenablingOneShotDoesNotInheritItsOldBaseline() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        _ = evaluate(99, at: 0, engine: &engine, rules: &rules)
        XCTAssertEqual(evaluate(101, at: 1, engine: &engine, rules: &rules).count, 1)
        rules[0].isEnabled = true
        XCTAssertTrue(evaluate(101, at: 2, engine: &engine, rules: &rules).isEmpty)
        _ = evaluate(99, at: 3, engine: &engine, rules: &rules)
        XCTAssertEqual(evaluate(101, at: 4, engine: &engine, rules: &rules).count, 1)
    }

    func testExchangeIsPartOfIdentityAndChangingItResetsTheBaseline() {
        var engine = PriceAlertEngine()
        let otherBTC = Contract(exchange: .bybit, instrumentID: "BTCUSDT", symbol: "BTC")
        var rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100, repeats: true, cooldown: 0)]
        _ = evaluate(99, at: 0, engine: &engine, rules: &rules)
        XCTAssertTrue(engine.evaluate(quote(101, at: 1, contract: otherBTC), rules: &rules, now: start.addingTimeInterval(1)).isEmpty)
        XCTAssertEqual(evaluate(101, at: 2, engine: &engine, rules: &rules).count, 1)
        rules[0].contract = otherBTC
        XCTAssertTrue(engine.evaluate(quote(101, at: 3, contract: otherBTC), rules: &rules, now: start.addingTimeInterval(3)).isEmpty)
        _ = engine.evaluate(quote(99, at: 4, contract: otherBTC), rules: &rules, now: start.addingTimeInterval(4))
        let events = engine.evaluate(quote(101, at: 5, contract: otherBTC), rules: &rules, now: start.addingTimeInterval(5))
        XCTAssertEqual(events.first?.contract, otherBTC)
    }

    func testInvalidPriceAndFutureTimestampNeverTrigger() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        _ = evaluate(99, at: 0, engine: &engine, rules: &rules)
        XCTAssertTrue(evaluate(.nan, at: 1, engine: &engine, rules: &rules).isEmpty)
        XCTAssertTrue(evaluate(0, at: 2, engine: &engine, rules: &rules).isEmpty)
        XCTAssertTrue(engine.evaluate(quote(101, at: 100), rules: &rules, now: start.addingTimeInterval(3)).isEmpty)
        XCTAssertTrue(evaluate(101, at: 4, engine: &engine, rules: &rules).isEmpty)
    }

    func testResetDoesNotProduceAnAlertFromAnOldSession() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100)]
        _ = evaluate(99, at: 0, engine: &engine, rules: &rules)
        engine.reset()
        XCTAssertTrue(evaluate(101, at: 1, engine: &engine, rules: &rules).isEmpty)
        _ = evaluate(99, at: 2, engine: &engine, rules: &rules)
        XCTAssertEqual(evaluate(101, at: 3, engine: &engine, rules: &rules).count, 1)
    }

    func testAcknowledgementRuleStaysArmedAndContractResetRebuildsCrossingBaseline() {
        var engine = PriceAlertEngine()
        var rules = [PriceAlert(contract: .btc, direction: .above, threshold: 100,
                                requiresAcknowledgement: true)]
        _ = evaluate(99, at: 0, engine: &engine, rules: &rules)
        XCTAssertEqual(evaluate(101, at: 1, engine: &engine, rules: &rules).count, 1)
        XCTAssertTrue(rules[0].isEnabled)
        XCTAssertNil(rules[0].lastTriggeredAt)
        engine.reset(contractID: Contract.btc.id)
        XCTAssertTrue(evaluate(101, at: 2, engine: &engine, rules: &rules).isEmpty)
        _ = evaluate(99, at: 3, engine: &engine, rules: &rules)
        XCTAssertEqual(evaluate(101, at: 4, engine: &engine, rules: &rules).count, 1)
    }

    func testAcknowledgingOneRulePreservesOtherRuleBaseline() {
        var engine = PriceAlertEngine()
        var rules = [
            PriceAlert(contract: .btc, direction: .above, threshold: 100,
                       repeats: true, cooldown: 0, requiresAcknowledgement: true),
            PriceAlert(contract: .btc, direction: .above, threshold: 100,
                       repeats: true, cooldown: 0, requiresAcknowledgement: true),
        ]
        let acknowledgedID = rules[0].id
        let otherID = rules[1].id

        _ = evaluate(99, at: 0, engine: &engine, rules: &rules)
        engine.reset(ruleID: acknowledgedID)
        let events = evaluate(101, at: 1, engine: &engine, rules: &rules)

        XCTAssertEqual(events.map(\.id), [otherID])
        _ = evaluate(99, at: 2, engine: &engine, rules: &rules)
        XCTAssertEqual(Set(evaluate(101, at: 3, engine: &engine, rules: &rules).map(\.id)),
                       Set([acknowledgedID, otherID]))
    }
}
