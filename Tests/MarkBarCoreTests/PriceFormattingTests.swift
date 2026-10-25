import XCTest
@testable import MarkBarCore

final class PriceFormattingTests: XCTestCase {
    func testExistingLargePricesKeepTwoDecimals() {
        XCTAssertEqual(PriceFormatting.compact(Decimal(string: "83273.9")!), "83,273.90")
        XCTAssertEqual(PriceFormatting.compact(Decimal(string: "2504.29")!), "2,504.29")
    }

    func testTinyPositivePricesNeverLookLikeZero() {
        XCTAssertEqual(PriceFormatting.compact(Decimal(string: "0.000012345678")!), "0.000012346")
        XCTAssertEqual(PriceFormatting.compact(Decimal(string: "0.000000000000000001")!), "0.000000000000000001")
        XCTAssertNotEqual(PriceFormatting.compact(Decimal(string: "0.00000000000000000001")!), "0.00")
    }

    func testExactPriceDoesNotRoundAlertInputs() {
        let price = Decimal(string: "0.123456789123456789")!
        XCTAssertEqual(PriceFormatting.exact(price), "0.123456789123456789")
        XCTAssertEqual(PriceFormatting.compact(0), "--")
    }
}
