import Foundation
import XCTest
@testable import MarkBarCore

private struct HTTPFixture: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = [Data("{}".utf8)]
    var waits = false
}

private final class HTTPFixtureRegistry: @unchecked Sendable {
    private struct Entry {
        let fixture: HTTPFixture
        var requests: [URLRequest] = []
        var stopped = false
        var loader: FixtureURLProtocol?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func add(_ fixture: HTTPFixture) -> String {
        let path = "/transport-test/\(UUID().uuidString)"
        lock.lock()
        entries[path] = Entry(fixture: fixture)
        lock.unlock()
        return path
    }
    func start(_ loader: FixtureURLProtocol) -> HTTPFixture? {
        guard let path = loader.request.url?.path else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[path] else { return nil }
        entry.requests.append(loader.request)
        entry.loader = loader
        entries[path] = entry
        return entry.fixture
    }
    func stop(_ path: String) {
        lock.lock()
        entries[path]?.stopped = true
        entries[path]?.loader = nil
        lock.unlock()
    }
    func snapshot(_ path: String) -> (requests: [URLRequest], stopped: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (entries[path]?.requests ?? [], entries[path]?.stopped ?? false)
    }
    func complete(_ path: String) {
        lock.lock()
        let entry = entries[path]
        lock.unlock()
        if let entry, !entry.stopped { entry.loader?.respond(entry.fixture) }
    }
    func remove(_ path: String) {
        lock.lock()
        entries.removeValue(forKey: path)
        lock.unlock()
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = HTTPFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.registry.start(self) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if !fixture.waits { respond(fixture) }
    }
    override func stopLoading() { Self.registry.stop(request.url?.path ?? "") }
    func respond(_ fixture: HTTPFixture) {
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status,
                                       httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        fixture.chunks.forEach { client?.urlProtocol(self, didLoad: $0) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class SystemHTTPClientTests: XCTestCase {
    func testAllOfficialMarketHostsAreAccepted() throws {
        for hostname in ["openapi.okx.com", "api.binance.com", "fapi.binance.com",
                         "dapi.binance.com", "api.bybit.com"] {
            let url = try HTTPTransportRequest.url(hostname: hostname, path: "/test", query: [], maxBytes: 64)
            XCTAssertEqual(url.host, hostname)
            XCTAssertEqual(url.scheme, "https")
        }
    }

    private func client(deadline: TimeInterval = 2) -> SystemHTTPClient {
        let configuration = SystemHTTPClient.defaultConfiguration()
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return SystemHTTPClient(configuration: configuration, deadline: deadline)
    }

    private func waitFor(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func testProductionConfigurationInheritsSystemProxyAndAvoidsPersistentState() {
        let configuration = SystemHTTPClient.defaultConfiguration()
        XCTAssertNil(configuration.connectionProxyDictionary)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 12)
        XCTAssertTrue(HTTPTransportFactory.make() is SystemHTTPClient)
        XCTAssertTrue(HTTPTransportFactory.make(mode: .physicalDirect) is PhysicalHTTPClient)
    }

    func testUsesOfficialHTTPSHostnameAndPreservesQuery() async throws {
        let path = FixtureURLProtocol.registry.add(HTTPFixture(chunks: [Data("bounded JSON".utf8)]))
        defer { FixtureURLProtocol.registry.remove(path) }
        let client = client()
        let data = try await client.get(hostname: "openapi.okx.com", path: path,
                                        query: [URLQueryItem(name: "instId", value: "BTC-USDT-SWAP")])
        XCTAssertEqual(data, Data("bounded JSON".utf8))
        let requests = FixtureURLProtocol.registry.snapshot(path).requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "openapi.okx.com")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "instId", value: "BTC-USDT-SWAP")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        await client.cancelAll()
    }

    func testUnapprovedHostAndInvalidLimitsAreRejectedBeforeRequest() async {
        let client = client()
        for (hostname, maxBytes) in [("1.1.1.1", 20), ("example.com", 20), ("openapi.okx.com", 0), ("openapi.okx.com", 4_194_305)] {
            do {
                _ = try await client.get(hostname: hostname, path: "/rejected", maxBytes: maxBytes)
                XCTFail("Expected validation error")
            } catch DirectNetworkError.invalidHTTPResponse { }
            catch { XCTFail("Unexpected \(error)") }
        }
        await client.cancelAll()
    }

    func testHTTPAccessDenialsPreserveStatusWithoutRetry() async {
        for status in [403, 451] {
            let path = FixtureURLProtocol.registry.add(HTTPFixture(status: status))
            defer { FixtureURLProtocol.registry.remove(path) }
            let client = client()
            do {
                _ = try await client.get(hostname: "fapi.binance.com", path: path)
                XCTFail("Expected HTTP \(status)")
            } catch DirectNetworkError.httpStatus(let actual) { XCTAssertEqual(actual, status) }
            catch { XCTFail("Unexpected \(error)") }
            XCTAssertEqual(FixtureURLProtocol.registry.snapshot(path).requests.count, 1)
            await client.cancelAll()
        }
    }

    func testContentLengthOverLimitIsRejected() async {
        let path = FixtureURLProtocol.registry.add(HTTPFixture(headers: ["Content-Length": "100"], chunks: []))
        defer { FixtureURLProtocol.registry.remove(path) }
        let client = client()
        do {
            _ = try await client.get(hostname: "api.bybit.com", path: path, maxBytes: 8)
            XCTFail("Expected bounded response")
        } catch DirectNetworkError.outputTooLarge { }
        catch { XCTFail("Unexpected \(error)") }
        await client.cancelAll()
    }

    func testUnknownLengthStreamingBodyCannotExceedLimit() async {
        let path = FixtureURLProtocol.registry.add(HTTPFixture(chunks: [Data(repeating: 1, count: 5), Data(repeating: 2, count: 4)]))
        defer { FixtureURLProtocol.registry.remove(path) }
        let client = client()
        do {
            _ = try await client.get(hostname: "openapi.okx.com", path: path, maxBytes: 8)
            XCTFail("Expected streaming size error")
        } catch DirectNetworkError.outputTooLarge { }
        catch { XCTFail("Unexpected \(error)") }
        await client.cancelAll()
    }

    func testBodyAtExactLimitIsAccepted() async throws {
        let path = FixtureURLProtocol.registry.add(HTTPFixture(chunks: [Data(repeating: 1, count: 4), Data(repeating: 2, count: 4)]))
        defer { FixtureURLProtocol.registry.remove(path) }
        let client = client()
        let data = try await client.get(hostname: "openapi.okx.com", path: path, maxBytes: 8)
        XCTAssertEqual(data.count, 8)
        await client.cancelAll()
    }

    func testTotalDeadlineCancelsStalledLoad() async {
        let path = FixtureURLProtocol.registry.add(HTTPFixture(waits: true))
        defer { FixtureURLProtocol.registry.remove(path) }
        let client = client(deadline: 0.15)
        let start = Date()
        do {
            _ = try await client.get(hostname: "openapi.okx.com", path: path)
            XCTFail("Expected timeout")
        } catch SystemNetworkError.timeout { }
        catch { XCTFail("Unexpected \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        let stopped = await waitFor { FixtureURLProtocol.registry.snapshot(path).stopped }
        XCTAssertTrue(stopped)
        await client.cancelAll()
    }

    func testTaskCancellationStopsURLSessionLoad() async {
        let path = FixtureURLProtocol.registry.add(HTTPFixture(waits: true))
        defer { FixtureURLProtocol.registry.remove(path) }
        let client = client()
        let request = Task { try await client.get(hostname: "openapi.okx.com", path: path) }
        let started = await waitFor { !FixtureURLProtocol.registry.snapshot(path).requests.isEmpty }
        XCTAssertTrue(started)
        request.cancel()
        do { _ = try await request.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected \(error)") }
        let stopped = await waitFor { FixtureURLProtocol.registry.snapshot(path).stopped }
        XCTAssertTrue(stopped)
        await client.cancelAll()
    }

    func testAlreadyCancelledTaskDoesNotCreateRequest() async {
        let path = FixtureURLProtocol.registry.add(HTTPFixture())
        defer { FixtureURLProtocol.registry.remove(path) }
        let client = client()
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.get(hostname: "openapi.okx.com", path: path)
        }
        do { _ = try await request.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(FixtureURLProtocol.registry.snapshot(path).requests.isEmpty)
        await client.cancelAll()
    }

    func testCancelAllAndNetworkInvalidationRetireOnlyOldSession() async throws {
        // Each control operation must kill old work and allow independent new work.
        for invalidate in [false, true] {
            let oldPath = FixtureURLProtocol.registry.add(HTTPFixture(waits: true))
            let newPath = FixtureURLProtocol.registry.add(HTTPFixture(chunks: [Data("new".utf8)], waits: true))
            defer {
                FixtureURLProtocol.registry.remove(oldPath)
                FixtureURLProtocol.registry.remove(newPath)
            }
            let client = client()
            let old = Task { try await client.get(hostname: "openapi.okx.com", path: oldPath) }
            let oldStarted = await waitFor { !FixtureURLProtocol.registry.snapshot(oldPath).requests.isEmpty }
            XCTAssertTrue(oldStarted)
            if invalidate { await client.invalidateNetworkCache() }
            else { await client.cancelAll() }
            let replacement = Task { try await client.get(hostname: "openapi.okx.com", path: newPath) }
            let newStarted = await waitFor { !FixtureURLProtocol.registry.snapshot(newPath).requests.isEmpty }
            XCTAssertTrue(newStarted)
            do { _ = try await old.value; XCTFail("Old request must be cancelled") }
            catch is CancellationError { }
            let oldStopped = await waitFor { FixtureURLProtocol.registry.snapshot(oldPath).stopped }
            XCTAssertTrue(oldStopped)
            XCTAssertFalse(FixtureURLProtocol.registry.snapshot(newPath).stopped)
            FixtureURLProtocol.registry.complete(newPath)
            let data = try await replacement.value
            XCTAssertEqual(data, Data("new".utf8))
            await client.cancelAll()
        }
    }

    func testRedirectDelegateRejectsEvenAnotherOfficialHost() async throws {
        let delegate = SystemHTTPSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://openapi.okx.com/test")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let redirected = URLRequest(url: URL(string: "https://api.bybit.com/test")!)
        let result: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertNil(result)
    }
}
