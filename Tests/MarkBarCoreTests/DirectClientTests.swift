import Foundation
import XCTest
@testable import MarkBarCore

final class DirectClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func response(instrument: String = "BTC-USDT-SWAP", type: String = "SWAP", price: String = "83195.2", timestamp: String = "1792000000000", code: String = "0") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "code": code,
            "data": [["instType": type, "instId": instrument, "markPx": price, "ts": timestamp]],
        ])
    }

    func testValidMarkPricePreservesDecimalAndExchangeTimestamp() throws {
        let quote = try OKXResponseParser.parse(response(), contract: .btc, receivedAt: now.addingTimeInterval(0.4))
        XCTAssertEqual(quote.price, Decimal(string: "83195.2"))
        XCTAssertEqual(quote.dataTime, now)
        XCTAssertEqual(quote.receivedAt, now.addingTimeInterval(0.4))
    }

    func testRejectsWrongInstrumentAndNonSwapData() {
        XCTAssertThrowsError(try OKXResponseParser.parse(response(instrument: "ETH-USDT-SWAP"), contract: .btc, receivedAt: now))
        XCTAssertThrowsError(try OKXResponseParser.parse(response(type: "FUTURES"), contract: .btc, receivedAt: now))
        XCTAssertThrowsError(try OKXResponseParser.parse(response(code: "50011"), contract: .btc, receivedAt: now))
    }

    func testRejectsInvalidPricesAndUnusableTimestamps() {
        for price in ["0", "-1", "NaN", "1e5", "1,234.5", " 100", "123\n"] {
            XCTAssertThrowsError(try OKXResponseParser.parse(response(price: price), contract: .btc, receivedAt: now), price)
        }
        for timestamp in ["1792000000", "1792000031000", "1791999939000", "not-a-time"] {
            XCTAssertThrowsError(try OKXResponseParser.parse(response(timestamp: timestamp), contract: .btc, receivedAt: now), timestamp)
        }
    }

    func testDNSFiltersFakePrivateReservedAndMalformedAddresses() {
        for address in ["198.18.0.1", "198.19.255.255", "10.0.0.1", "172.16.1.1", "172.31.1.1", "192.168.1.1", "127.0.0.1", "169.254.1.1", "100.64.1.1", "0.0.0.0", "224.0.0.1", "255.255.255.255", "192.0.2.1", "198.51.100.1", "203.0.113.1", "::1", "1.1.1.999", "1.1.1.01", "1.1.1", "1.1.1.1\n"] {
            XCTAssertFalse(PublicIPv4Address.isAllowed(address), address)
        }
        for address in ["1.1.1.1", "104.18.10.2", "172.32.0.1", "100.128.0.1"] {
            XCTAssertTrue(PublicIPv4Address.isAllowed(address), address)
        }
    }

    func testDNSRespectsShortestTTLAndDeduplicates() throws {
        let data = Data(#"{"Status":0,"TC":false,"Answer":[{"type":5,"TTL":30,"data":"cdn.example"},{"type":1,"TTL":60,"data":"1.1.1.1"},{"type":1,"TTL":45,"data":"1.1.1.1"},{"type":1,"TTL":300,"data":"104.18.10.2"},{"type":1,"TTL":1,"data":"198.18.0.1"}]}"#.utf8)
        let resolution = try DoHResponseParser.parse(data, now: now)
        XCTAssertEqual(resolution.addresses, ["1.1.1.1", "104.18.10.2"])
        XCTAssertEqual(resolution.expiresAt, now.addingTimeInterval(30))
    }

    func testDNSRejectsEmptyTruncatedAndFakeOnlyAnswers() {
        for json in [#"{"Status":3}"#, #"{"Status":0,"TC":true,"Answer":[{"type":1,"TTL":60,"data":"1.1.1.1"}]}"#, #"{"Status":0,"Answer":[{"type":1,"TTL":60,"data":"198.18.0.1"}]}"#] {
            XCTAssertThrowsError(try DoHResponseParser.parse(Data(json.utf8), now: now))
        }
    }
}
