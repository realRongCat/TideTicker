import Foundation
import XCTest
@testable import MarkBarCore

final class PreferencesTests: XCTestCase {
    func testNewPreferencesDefaultToSystemNetwork() {
        XCTAssertEqual(TidePreferences.default.networkMode, .system)
        XCTAssertEqual(TidePreferences().networkMode, .system)
    }

    func testNetworkModesRoundTripAndSurviveNormalization() throws {
        for mode in [NetworkMode.system, .physicalDirect] {
            let alert = PriceAlert(contract: .eth, direction: .below,
                                   threshold: Decimal(string: "0.00000123")!, repeats: true, cooldown: 600)
            var preferences = TidePreferences(networkMode: mode,
                                              pinnedIDs: [Contract.eth.id, "missing"],
                                              refreshInterval: 7, alerts: [alert])
            preferences.normalize()
            XCTAssertEqual(preferences.networkMode, mode)
            XCTAssertEqual(preferences.refreshInterval, 5)
            XCTAssertEqual(preferences.pinnedIDs, [Contract.eth.id])
            XCTAssertEqual(preferences.alerts, [alert])
            let decoded = try JSONDecoder().decode(TidePreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(decoded, preferences)

            let profiles = ["okx": preferences]
            let restored = try JSONDecoder().decode([String: TidePreferences].self, from: JSONEncoder().encode(profiles))
            XCTAssertEqual(restored, profiles)
        }
    }

    func testInvalidExplicitNetworkModeIsNotSilentlyDefaulted() throws {
        let encoded = try JSONEncoder().encode(TidePreferences.default)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for invalid in ["unsupported-mode", NSNull(), 1] as [Any] {
            var object = original
            object["networkMode"] = invalid
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(TidePreferences.self, from: data)) { error in
                XCTAssertTrue(error is DecodingError)
            }
        }
    }

    func testOriginalPreferencesFieldsRemainRequired() throws {
        let encoded = try JSONEncoder().encode(TidePreferences.default)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for field in ["exchange", "watchlist", "pinnedIDs", "refreshInterval", "showsMarketDetails", "alerts"] {
            var object = original
            object.removeValue(forKey: field)
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(TidePreferences.self, from: data)) { error in
                guard case DecodingError.keyNotFound(let key, _) = error else {
                    return XCTFail("Missing \(field) should remain a required-field error: \(error)")
                }
                XCTAssertEqual(key.stringValue, field)
            }
        }
    }

    func testDefaultAndEmptyConfigurationDoNotInventPins() {
        XCTAssertEqual(TidePreferences.default.pinnedContracts, [.btc, .eth])
        var settings = TidePreferences(watchlist: [], pinnedIDs: [Contract.btc.id])
        settings.normalize()
        XCTAssertTrue(settings.watchlist.isEmpty)
        XCTAssertTrue(settings.pinnedContracts.isEmpty)
        settings.watchlist = [.btc]
        settings.normalize()
        XCTAssertTrue(settings.pinnedContracts.isEmpty)
    }

    func testWatchlistIdentityDeduplicationExchangeAndLimit() {
        let foreign = Contract(exchange: .binance, instrumentID: "BTCUSDT", symbol: "BTC")
        let renamedBTC = Contract(exchange: .okx, instrumentID: Contract.btc.instrumentID, symbol: "Bitcoin")
        let additional = (0..<25).map { Contract(exchange: .okx, instrumentID: "COIN\($0)-USDT-SWAP", symbol: "COIN\($0)") }
        var settings = TidePreferences(watchlist: [.btc, renamedBTC, foreign] + additional)
        settings.normalize()
        XCTAssertEqual(settings.watchlist.count, 20)
        XCTAssertEqual(settings.watchlist.first, .btc)
        XCTAssertEqual(Set(settings.watchlist.map(\.id)).count, 20)
        XCTAssertTrue(settings.watchlist.allSatisfy { $0.exchange == .okx })
    }

    func testLegacyPreferencesDefaultNewAcknowledgementFields() throws {
        let encoded = try JSONEncoder().encode(TidePreferences.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "pendingAlerts")
        if var alerts = object["alerts"] as? [[String: Any]] {
            for index in alerts.indices { alerts[index].removeValue(forKey: "requiresAcknowledgement") }
            object["alerts"] = alerts
        }
        let decoded = try JSONDecoder().decode(TidePreferences.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.pendingAlerts.isEmpty)
        XCTAssertTrue(decoded.alerts.allSatisfy { !$0.requiresAcknowledgement })
    }

    func testMixedMarketsRoundTripAndInvalidMarketCombinationsAreRemoved() throws {
        let spot = Contract(exchange: .okx, instrumentID: "BTC-USDT", symbol: "BTC",
                            marketKind: .spot, priceKind: .last)
        let inverse = Contract(exchange: .okx, instrumentID: "BTC-USD-SWAP", symbol: "BTC",
                               marketKind: .inversePerpetual, quoteCurrency: "USD",
                               settlementCurrency: "BTC")
        let invalid = Contract(exchange: .okx, instrumentID: "BTC-USDT", symbol: "BTC",
                               marketKind: .spot, priceKind: .mark)
        var preferences = TidePreferences(watchlist: [.btc, spot, inverse, invalid],
                                          pinnedIDs: [spot.id, inverse.id])
        preferences.normalize()
        XCTAssertEqual(preferences.watchlist, [.btc, spot, inverse])
        XCTAssertEqual(preferences.pinnedContracts, [spot, inverse])
        XCTAssertEqual(try JSONDecoder().decode(TidePreferences.self,
                                                 from: JSONEncoder().encode(preferences)), preferences)
    }

    func testPinsKeepExplicitOrderAndAllowOneSlot() {
        var settings = TidePreferences(pinnedIDs: [Contract.eth.id, "missing", Contract.eth.id, Contract.btc.id])
        settings.normalize()
        XCTAssertEqual(settings.pinnedContracts, [.eth, .btc])
        settings.pinnedIDs = [Contract.eth.id]
        settings.normalize()
        XCTAssertEqual(settings.pinnedContracts, [.eth])
    }

    func testChangingExchangeDoesNotRelabelOldContractsOrAlerts() {
        var settings = TidePreferences(alerts: [PriceAlert(contract: .btc, direction: .above, threshold: 100)])
        settings.exchange = .bybit
        settings.normalize()
        XCTAssertTrue(settings.watchlist.isEmpty)
        XCTAssertTrue(settings.pinnedIDs.isEmpty)
        XCTAssertTrue(settings.alerts.isEmpty)
    }

    func testRefreshChoicesAndStaleWindow() {
        for (interval, stale) in [(5.0, 20.0), (10, 30), (15, 45), (30, 90)] {
            var settings = TidePreferences(refreshInterval: interval)
            settings.normalize()
            XCTAssertEqual(settings.refreshInterval, interval)
            XCTAssertEqual(settings.staleAfter, stale)
        }
        for interval in [0, 7, -5, .infinity, .nan] as [TimeInterval] {
            var settings = TidePreferences(refreshInterval: interval)
            settings.normalize()
            XCTAssertEqual(settings.refreshInterval, 5)
        }
    }

    func testAlertNormalizationRejectsInvalidThresholdsAndRepairsCooldown() {
        let valid = PriceAlert(contract: .btc, direction: .above, threshold: Decimal(string: "0.00000123")!, cooldown: -1)
        var settings = TidePreferences(alerts: [valid, valid,
            PriceAlert(contract: .btc, direction: .above, threshold: 0),
            PriceAlert(contract: .btc, direction: .above, threshold: -1),
            PriceAlert(contract: .btc, direction: .above, threshold: .nan),
        ])
        settings.normalize()
        XCTAssertEqual(settings.alerts.count, 1)
        XCTAssertEqual(settings.alerts[0].threshold, valid.threshold)
        XCTAssertEqual(settings.alerts[0].cooldown, 300)
    }

    func testRoundTripPreservesSmallThresholdAndTriggerState() throws {
        let alert = PriceAlert(contract: .eth, direction: .below, threshold: Decimal(string: "0.00000123")!,
                               isEnabled: false, repeats: true, cooldown: 600,
                               lastTriggeredAt: Date(timeIntervalSince1970: 1_800_000_000))
        let settings = TidePreferences(pinnedIDs: [Contract.eth.id], refreshInterval: 15,
                                       showsMarketDetails: true, alerts: [alert])
        let decoded = try JSONDecoder().decode(TidePreferences.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testLegacyPreferencesAndSourceProfilesKeepSavedCrossingsAndCooldowns() throws {
        // This is the on-disk shape written before the additional conditions.
        let legacyJSON = """
        {
          "exchange": "okx",
          "watchlist": [
            {"exchange":"okx","instrumentID":"BTC-USDT-SWAP","symbol":"BTC"},
            {"exchange":"okx","instrumentID":"ETH-USDT-SWAP","symbol":"ETH"}
          ],
          "pinnedIDs": ["okx:USDT:perpetual:mark:ETH-USDT-SWAP"],
          "refreshInterval": 15,
          "showsMarketDetails": true,
          "alerts": [
            {
              "id":"00000000-0000-0000-0000-000000000001",
              "contract":{"exchange":"okx","instrumentID":"BTC-USDT-SWAP","symbol":"BTC"},
              "direction":"above","threshold":85000.125,
              "isEnabled":true,"repeats":true,"cooldown":300,"lastTriggeredAt":700000000
            },
            {
              "id":"00000000-0000-0000-0000-000000000002",
              "contract":{"exchange":"okx","instrumentID":"ETH-USDT-SWAP","symbol":"ETH"},
              "direction":"below","threshold":0.00000123,
              "isEnabled":false,"repeats":false,"cooldown":600,"lastTriggeredAt":700000010
            }
          ]
        }
        """
        let expected = TidePreferences(networkMode: .physicalDirect, pinnedIDs: [Contract.eth.id], refreshInterval: 15,
            showsMarketDetails: true, alerts: [
                PriceAlert(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    contract: .btc, direction: .above, threshold: Decimal(string: "85000.125")!,
                    repeats: true, cooldown: 300, lastTriggeredAt: Date(timeIntervalSinceReferenceDate: 700_000_000)),
                PriceAlert(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    contract: .eth, direction: .below, threshold: Decimal(string: "0.00000123")!,
                    isEnabled: false, repeats: false, cooldown: 600,
                    lastTriggeredAt: Date(timeIntervalSinceReferenceDate: 700_000_010)),
            ])
        var decoded = try JSONDecoder().decode(TidePreferences.self, from: Data(legacyJSON.utf8))
        decoded.normalize()
        XCTAssertEqual(decoded.networkMode, .physicalDirect)
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(try JSONDecoder().decode(TidePreferences.self, from: JSONEncoder().encode(decoded)), expected)

        let profileData = Data("{\"okx\":\(legacyJSON)}".utf8)
        let profiles = try JSONDecoder().decode([String: TidePreferences].self, from: profileData)
        XCTAssertEqual(profiles["okx"]?.networkMode, .physicalDirect)
        XCTAssertEqual(profiles, ["okx": expected])
        let restoredProfiles = try JSONDecoder().decode([String: TidePreferences].self, from: JSONEncoder().encode(profiles))
        XCTAssertEqual(restoredProfiles, profiles)
    }

    func testAdditionalAlertConditionsRoundTripWithExactThresholds() throws {
        let alerts = [AlertDirection.crossing, .greaterThan, .lessThan].map {
            PriceAlert(contract: .eth, direction: $0, threshold: Decimal(string: "0.00000123")!, repeats: true)
        }
        let preferences = TidePreferences(alerts: alerts)
        var decoded = try JSONDecoder().decode(TidePreferences.self, from: JSONEncoder().encode(preferences))
        decoded.normalize()
        XCTAssertEqual(decoded, preferences)
    }
}
