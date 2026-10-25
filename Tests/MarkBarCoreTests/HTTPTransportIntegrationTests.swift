import Foundation
import XCTest
@testable import MarkBarCore

private actor RecordingTransport: HTTPTransport {
    struct Request: Sendable {
        let hostname: String
        let path: String
        let query: [URLQueryItem]
        let maxBytes: Int
    }
    private(set) var requests: [Request] = []
    private(set) var cancellations = 0
    private(set) var invalidations = 0

    func get(hostname: String, path: String, query: [URLQueryItem], maxBytes: Int) async throws -> Data {
        requests.append(Request(hostname: hostname, path: path, query: query, maxBytes: maxBytes))
        if path == "/v5/market/instruments-info" {
            let category = query.first(where: { $0.name == "category" })?.value
            switch category {
            case "spot":
                return Data(#"{"retCode":0,"result":{"category":"spot","list":[{"symbol":"BTCUSDT","status":"Trading","baseCoin":"BTC","quoteCoin":"USDT"}]}}"#.utf8)
            case "linear":
                return Data(#"{"retCode":0,"result":{"category":"linear","list":[{"symbol":"BTCUSDT","contractType":"LinearPerpetual","status":"Trading","baseCoin":"BTC","quoteCoin":"USDT","settleCoin":"USDT","isPreListing":false}]}}"#.utf8)
            case "inverse":
                return Data(#"{"retCode":0,"result":{"category":"inverse","list":[{"symbol":"BTCUSD","contractType":"InversePerpetual","status":"Trading","baseCoin":"BTC","quoteCoin":"USD","settleCoin":"BTC","isPreListing":false}]}}"#.utf8)
            default: throw DirectNetworkError.invalidHTTPResponse
            }
        }
        guard path == "/v5/market/tickers", query.contains(URLQueryItem(name: "symbol", value: "BTCUSDT")) else {
            throw DirectNetworkError.invalidHTTPResponse
        }
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        return Data("""
        {"retCode":0,"time":\(milliseconds),"result":{"category":"linear","list":[{"symbol":"BTCUSDT","markPrice":"100.01","lastPrice":"100.02","price24hPcnt":"0.012","fundingRate":"0.0001"}]}}
        """.utf8)
    }
    func cancelAll() async { cancellations += 1 }
    func invalidateNetworkCache() async { invalidations += 1 }
}

private actor RefusingTransport: HTTPTransport {
    private(set) var paths: [String] = []
    func get(hostname: String, path: String, query: [URLQueryItem], maxBytes: Int) async throws -> Data {
        paths.append(path)
        throw DirectNetworkError.httpStatus(451)
    }
    func cancelAll() async {}
    func invalidateNetworkCache() async {}
}

@MainActor
final class HTTPTransportIntegrationTests: XCTestCase {
    func testConnectionDiagnosticsRunsCatalogueThenRepresentativeQuote() async throws {
        let transport = RecordingTransport()
        let client = MarketDataClient(transport: transport)
        let preferred = Contract(exchange: .bybit, instrumentID: "BTCUSDT", symbol: "BTC")
        let report = try await client.connectionDiagnostics(
            exchange: .bybit,
            networkMode: .system,
            appVersion: "0.1.0 (1)",
            preferredContract: preferred
        )
        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.steps.map(\.stage), [.catalogue, .quote])
        XCTAssertEqual(report.steps.first?.detail, "已读取 3 个可用品种")
        XCTAssertEqual(report.steps.last?.hostnames, ["api.bybit.com"])
        XCTAssertTrue(report.steps.last?.detail.contains("标记价") == true)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.path == "/v5/market/instruments-info" }.count, 3)
        XCTAssertEqual(requests.filter { $0.path == "/v5/market/tickers" }.count, 1)
    }

    func testConnectionDiagnosticsStopsAfterCatalogueAccessDenial() async throws {
        let transport = RefusingTransport()
        let client = MarketDataClient(transport: transport)
        let report = try await client.connectionDiagnostics(
            exchange: .okx,
            networkMode: .physicalDirect,
            appVersion: "0.1.0 (1)",
            preferredContract: .btc
        )
        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.steps.map(\.stage), [.catalogue])
        XCTAssertEqual(report.steps.first?.errorCategory, .http451)
        let paths = await transport.paths
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.allSatisfy { $0 == "/api/v5/public/instruments" })
        XCTAssertFalse(paths.contains("/api/v5/public/mark-price"))
    }

    func testCatalogQuoteDetailsAndLifecycleUseOneInjectedTransport() async throws {
        let transport = RecordingTransport()
        let client = MarketDataClient(transport: transport)
        let contracts = try await client.instruments(for: .bybit)
        XCTAssertEqual(Set(contracts.map(\.marketKind)), Set(MarketKind.allCases))
        let contract = try XCTUnwrap(contracts.first { $0.marketKind == .linearPerpetual })
        let quote = try await client.fetch(contract)
        let details = try await client.details(for: contract)
        XCTAssertEqual(quote.price, Decimal(string: "100.01"))
        XCTAssertEqual(details.lastPrice, Decimal(string: "100.02"))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.hostname), Array(repeating: "api.bybit.com", count: 5))
        XCTAssertEqual(requests.filter { $0.path == "/v5/market/instruments-info" }.count, 3)
        XCTAssertEqual(requests.filter { $0.path == "/v5/market/tickers" }.count, 2)
        XCTAssertEqual(requests.filter { $0.maxBytes == 4_194_304 }.count, 3)
        XCTAssertEqual(requests.filter { $0.maxBytes == 65_536 }.count, 2)
        await client.invalidateNetworkCache()
        await client.cancelAll()
        let invalidations = await transport.invalidations
        let cancellations = await transport.cancellations
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(cancellations, 1)
    }
}
