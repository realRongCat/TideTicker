import Foundation
import XCTest
@testable import MarkBarCore

final class ConnectionDiagnosticsTests: XCTestCase {
    func testTransportFailuresMapToActionableCategories() {
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(DirectNetworkError.timeout), .timeout)
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(DirectNetworkError.dnsResolution), .dns)
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(DirectNetworkError.noPhysicalInterface), .physicalInterface)
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(DirectNetworkError.httpStatus(403)), .http403)
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(DirectNetworkError.httpStatus(451)), .http451)
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(DirectNetworkError.httpStatus(500)), .http)
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(DirectNetworkError.outputTooLarge), .responseTooLarge)
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(SystemNetworkError.proxy), .proxy)
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(SystemNetworkError.tls), .tls)
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(MarketDataError.malformed), .parsing)
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(MarketDataError.rejected("50011")), .business)
        XCTAssertEqual(ConnectionDiagnosticErrorCategory.classify(CancellationError()), .cancelled)
    }

    func testEveryCategoryHasUserFacingTitleAndRecommendation() {
        for category in ConnectionDiagnosticErrorCategory.allCases {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.recommendation.isEmpty)
        }
    }

    func testCopiedReportRedactsPathsIPsAndCredentialLikeValues() {
        let step = ConnectionDiagnosticStep(
            stage: .quote,
            hostnames: ["api.bybit.com"],
            market: "USDT 永续",
            duration: 1.25,
            succeeded: false,
            detail: "proxy=user:pass 192.168.1.2 /Users/alice/private.json token=secret",
            errorCategory: .proxy
        )
        let report = ConnectionDiagnosticReport(
            appVersion: "0.1.0 /tmp/build-secret",
            exchange: .bybit,
            networkMode: .system,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 1.25,
            steps: [step]
        )
        let copy = report.copyText
        XCTAssertFalse(copy.contains("192.168.1.2"))
        XCTAssertFalse(copy.contains("/Users/alice"))
        XCTAssertFalse(copy.contains("/tmp/build-secret"))
        XCTAssertFalse(copy.contains("user:pass"))
        XCTAssertFalse(copy.contains("token=secret"))
        XCTAssertTrue(copy.contains("api.bybit.com"))
        XCTAssertTrue(copy.contains("系统代理连接失败"))
    }

    func testSuccessfulReportRequiresBothCatalogueAndQuoteStages() {
        let catalogue = ConnectionDiagnosticStep(stage: .catalogue, hostnames: ["openapi.okx.com"],
            market: "现货与永续", duration: 0.2, succeeded: true, detail: "已读取 10 个可用品种")
        let quote = ConnectionDiagnosticStep(stage: .quote, hostnames: ["openapi.okx.com"],
            market: "USDT 永续", duration: 0.1, succeeded: true, detail: "BTC/USDT")
        let partial = ConnectionDiagnosticReport(appVersion: "0.1.0", exchange: .okx, networkMode: .system,
            startedAt: Date(), duration: 0.2, steps: [catalogue])
        let complete = ConnectionDiagnosticReport(appVersion: "0.1.0", exchange: .okx, networkMode: .system,
            startedAt: Date(), duration: 0.3, steps: [catalogue, quote])
        XCTAssertFalse(partial.succeeded)
        XCTAssertTrue(complete.succeeded)
    }
}
