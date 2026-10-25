import Foundation
import Darwin

/// Fetches public mark prices over an explicitly bound physical interface.
/// No credentials, proxy configuration changes, or disabled TLS checks are involved.
public actor DirectOKXClient {
    private let client = MarketDataClient(networkMode: .physicalDirect)
    public init() {}
    public func fetch(_ contract: Contract) async throws -> MarkQuote {
        guard contract.exchange == .okx else { throw MarketProviderError(exchange: contract.exchange, reason: "此兼容客户端只接受 OKX 品种") }
        return try await client.fetch(contract)
    }
    public func invalidateNetworkCache() async { await client.invalidateNetworkCache() }
    public func cancelAll() async { await client.cancelAll() }
}

actor PhysicalHTTPClient: HTTPTransport {
    private struct DNSKey: Hashable { let hostname: String; let interface: String }
    private let runner = BoundedProcessRunner()
    private var dnsCache: [DNSKey: DNSResolution] = [:]
    private var preferredInterface: String?

    public init() {}

    public func invalidateNetworkCache() async {
        dnsCache.removeAll()
        preferredInterface = nil
    }

    public func cancelAll() async {
        runner.cancelAll()
    }

    func get(hostname: String, path: String, query: [URLQueryItem] = [], maxBytes: Int = 65_536) async throws -> Data {
        try Task.checkCancellation()
        let url = try HTTPTransportRequest.url(hostname: hostname, path: path, query: query, maxBytes: maxBytes).absoluteString
        let deadline = Date().addingTimeInterval(12)
        var candidates = PhysicalInterfaces.activeNames()
        if let preferredInterface, let index = candidates.firstIndex(of: preferredInterface) {
            candidates.remove(at: index)
            candidates.insert(preferredInterface, at: 0)
        }
        guard !candidates.isEmpty else { throw DirectOKXError.noPhysicalInterface }
        var lastError: Error = DirectOKXError.noPhysicalInterface

        for interface in candidates.prefix(3) {
            try Task.checkCancellation()
            guard deadline.timeIntervalSinceNow > 0.2 else { break }
            do {
                try await verifyPhysicalRoute(interface, deadline: deadline)
                let resolution = try await resolve(hostname: hostname, on: interface, deadline: deadline)
                for address in resolution.addresses.prefix(3) {
                    try Task.checkCancellation()
                    guard deadline.timeIntervalSinceNow > 0.2 else { break }
                    do {
                        let body = try await request(
                            url: url, interface: interface,
                            extraArguments: ["--resolve", "\(hostname):443:\(address)"],
                            deadline: deadline, maxBytes: maxBytes
                        )
                        preferredInterface = interface
                        return body
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                        // HTTP rejection is not retried through another address or interface.
                        if case DirectNetworkError.httpStatus = error { throw error }
                    }
                }
                dnsCache.removeValue(forKey: DNSKey(hostname: hostname, interface: interface))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if case DirectNetworkError.httpStatus = error { throw error }
            }
        }
        try Task.checkCancellation()
        throw lastError
    }

    private func verifyPhysicalRoute(_ interface: String, deadline: Date) async throws {
        let output = try await runner.run(
            executable: "/sbin/route",
            arguments: ["-n", "get", "-ifscope", interface, "default"],
            timeout: min(1.5, max(0.1, deadline.timeIntervalSinceNow)), maxBytes: 8_192
        )
        let route = String(decoding: output.stdout, as: UTF8.self)
        let actualInterface = route.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "interface" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }.first
        guard output.status == 0, actualInterface == interface else {
            throw DirectOKXError.noDirectRoute(interface)
        }
    }

    private func resolve(hostname: String, on interface: String, deadline: Date) async throws -> DNSResolution {
        let key = DNSKey(hostname: hostname, interface: interface)
        if let cached = dnsCache[key], cached.expiresAt > Date() { return cached }
        // Using the literal resolver address avoids the system's Fake-IP DNS entirely.
        // Cloudflare's certificate covers 1.1.1.1; curl retains normal TLS verification.
        let body = try await request(
            url: "https://1.1.1.1/dns-query?name=\(hostname)&type=A",
            interface: interface,
            extraArguments: ["--header", "Accept: application/dns-json"],
            deadline: deadline, maxBytes: 65_536
        )
        let resolution = try DoHResponseParser.parse(body, now: Date())
        dnsCache[key] = resolution
        return resolution
    }

    private func request(url: String, interface: String, extraArguments: [String], deadline: Date, maxBytes: Int) async throws -> Data {
        let budget = min(4.5, deadline.timeIntervalSinceNow)
        guard budget > 0.1 else { throw DirectOKXError.timeout }
        let arguments = [
            // --disable MUST be first, otherwise ~/.curlrc could override direct routing.
            "--disable", "--silent", "--show-error", "--proxy", "", "--noproxy", "*",
            "--interface", interface, "--ipv4", "--proto", "=https",
            "--connect-timeout", String(format: "%.2f", min(2.5, budget)),
            "--max-time", String(format: "%.2f", budget),
            "--max-filesize", String(maxBytes), "--write-out", "\n%{http_code}"
        ] + extraArguments + [url]
        let output = try await runner.run(
            executable: "/usr/bin/curl", arguments: arguments,
            timeout: budget + 0.3, maxBytes: maxBytes + 8_192
        )
        guard output.status == 0 else {
            if output.status == 28 { throw DirectOKXError.timeout }
            // curl diagnostics include no secrets: these requests have no credentials.
            let detail = String(decoding: output.stderr.prefix(500), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DirectOKXError.transport(detail.isEmpty ? "curl 错误 \(output.status)" : detail)
        }
        guard let divider = output.stdout.lastIndex(of: 10),
              let status = Int(String(decoding: output.stdout[(divider + 1)...], as: UTF8.self)) else {
            throw DirectOKXError.invalidHTTPResponse
        }
        guard status == 200 else { throw DirectOKXError.httpStatus(status) }
        return Data(output.stdout[..<divider])
    }
}

public typealias DirectOKXError = DirectNetworkError

public enum DirectNetworkError: LocalizedError, Sendable {
    case noPhysicalInterface
    case noDirectRoute(String)
    case dnsResolution
    case timeout
    case outputTooLarge
    case invalidHTTPResponse
    case httpStatus(Int)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .noPhysicalInterface: return "未找到已连接的 Wi-Fi 或有线网卡"
        case .noDirectRoute(let name): return "网卡 \(name) 没有可用的直连路由"
        case .dnsResolution: return "无法取得服务的真实公网地址"
        case .timeout: return "物理网卡直连请求超时"
        case .outputTooLarge: return "服务器响应超过大小限制"
        case .invalidHTTPResponse: return "服务器 HTTP 响应无效"
        case .httpStatus(451): return "服务端因地区或访问政策限制拒绝请求（HTTP 451）"
        case .httpStatus(403): return "服务端拒绝访问（HTTP 403）"
        case .httpStatus(let status): return "服务返回 HTTP \(status)"
        case .transport(let detail): return "直连失败：\(detail)"
        }
    }
}

enum MarketDataError: LocalizedError, Sendable {
    case malformed
    case rejected(String)
    case wrongInstrument
    case invalidPrice
    case invalidTimestamp
    case stale

    var errorDescription: String? {
        switch self {
        case .malformed: return "行情响应格式错误"
        case .rejected(let code): return "行情请求失败（\(code)）"
        case .wrongInstrument: return "返回了不匹配的市场品种"
        case .invalidPrice: return "返回了无效的行情价格"
        case .invalidTimestamp: return "返回了无效的行情时间"
        case .stale: return "返回的行情已超过 60 秒"
        }
    }
}

enum OKXResponseParser {
    private struct Response: Decodable {
        let code: String
        let data: [Row]
    }
    private struct Row: Decodable {
        let instType: String
        let instId: String
        let markPx: String
        let ts: String
    }

    static func parse(_ data: Data, contract: Contract, receivedAt: Date) throws -> MarkQuote {
        guard contract.exchange == .okx, contract.marketKind.isPerpetual,
              contract.priceKind == .mark else { throw MarketDataError.wrongInstrument }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw MarketDataError.malformed }
        guard response.code == "0" else { throw MarketDataError.rejected(response.code) }
        guard response.data.count == 1, let row = response.data.first,
              row.instType == "SWAP", row.instId == contract.instrumentID else { throw MarketDataError.wrongInstrument }
        guard row.markPx.range(of: #"\A(0|[1-9][0-9]{0,17})(\.[0-9]{1,18})?\z"#, options: .regularExpression) != nil,
              let price = Decimal(string: row.markPx, locale: Locale(identifier: "en_US_POSIX")), price > 0 else {
            throw MarketDataError.invalidPrice
        }
        guard row.ts.count == 13, row.ts.allSatisfy({ $0.isASCII && $0.isNumber }),
              let milliseconds = Int64(row.ts), milliseconds >= 1_577_836_800_000 else { throw MarketDataError.invalidTimestamp }
        let dataTime = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        guard dataTime.timeIntervalSince(receivedAt) <= 30 else { throw MarketDataError.invalidTimestamp }
        guard receivedAt.timeIntervalSince(dataTime) <= 60 else { throw MarketDataError.stale }
        return MarkQuote(contract: contract, price: price, dataTime: dataTime, receivedAt: receivedAt)
    }
}

struct DNSResolution: Sendable {
    let addresses: [String]
    let expiresAt: Date
}

enum DoHResponseParser {
    private struct Response: Decodable {
        let Status: Int
        let TC: Bool?
        let Answer: [Answer]?
    }
    private struct Answer: Decodable {
        let type: Int
        let TTL: Int
        let data: String
    }

    static func parse(_ data: Data, now: Date) throws -> DNSResolution {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.Status == 0, response.TC != true else { throw DirectOKXError.dnsResolution }
        let records = (response.Answer ?? []).filter { $0.type == 1 && $0.TTL >= 0 && PublicIPv4Address.isAllowed($0.data) }
        var seen = Set<String>()
        let addresses = records.compactMap { seen.insert($0.data).inserted ? $0.data : nil }
        guard !addresses.isEmpty else { throw DirectOKXError.dnsResolution }
        // Respect the shortest upstream TTL. A zero TTL deliberately disables reuse.
        let aliasTTLs = (response.Answer ?? []).filter { $0.type == 5 && $0.TTL >= 0 }.map(\.TTL)
        let ttl = min((records.map(\.TTL) + aliasTTLs).min() ?? 0, 600)
        return DNSResolution(addresses: addresses, expiresAt: now.addingTimeInterval(TimeInterval(ttl)))
    }
}

enum PublicIPv4Address {
    static func isAllowed(_ string: String) -> Bool {
        let components = string.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        var bytes: [UInt8] = []
        for component in components {
            guard !component.isEmpty, component.count <= 3,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  (component.count == 1 || component.first != "0"), let byte = UInt8(component) else { return false }
            bytes.append(byte)
        }
        let a = bytes[0], b = bytes[1], c = bytes[2]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99)) { return false }
        if a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)) { return false }
        if a == 203 && b == 0 && c == 113 { return false }
        return true
    }
}

private enum PhysicalInterfaces {
    static func activeNames() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var names = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = current {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            let flags = Int32(bitPattern: entry.ifa_flags)
            if name.range(of: #"^en[0-9]+$"#, options: .regularExpression) != nil,
               flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
               flags & IFF_LOOPBACK == 0, entry.ifa_addr?.pointee.sa_family == UInt8(AF_INET) {
                names.insert(name)
            }
            current = entry.ifa_next
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

private struct ProcessOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// Blocking pipe reads run on utility queues; the main actor never waits on a child.
private final class BoundedProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [UUID: ProcessJob] = [:]

    func cancelAll() {
        lock.lock()
        let active = Array(jobs.values)
        lock.unlock()
        active.forEach { $0.stop(.cancelled) }
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval, maxBytes: Int) async throws -> ProcessOutput {
        let id = UUID()
        let job = ProcessJob(maxBytes: maxBytes)
        register(job, id: id)
        defer { unregister(id) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try job.execute(executable: executable, arguments: arguments, timeout: timeout)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            job.stop(.cancelled)
        }
    }

    private func register(_ job: ProcessJob, id: UUID) {
        lock.lock()
        jobs[id] = job
        lock.unlock()
    }

    private func unregister(_ id: UUID) {
        lock.lock()
        jobs.removeValue(forKey: id)
        lock.unlock()
    }
}

private final class ProcessJob: @unchecked Sendable {
    enum StopReason { case cancelled, timeout, tooLarge }
    private let lock = NSLock()
    private var process: Process?
    private var reason: StopReason?
    private var totalBytes = 0
    private var stdout = Data()
    private var stderr = Data()
    private let maxBytes: Int

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func stop(_ stopReason: StopReason) {
        lock.lock()
        if reason == nil { reason = stopReason }
        let child = process
        if let child, child.isRunning { child.terminate() }
        lock.unlock()
        if let child {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
    }

    func execute(executable: String, arguments: [String], timeout: TimeInterval) throws -> ProcessOutput {
        let child = Process()
        let outputPipe = Pipe(), errorPipe = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = outputPipe
        child.standardError = errorPipe

        lock.lock()
        if reason != nil {
            lock.unlock()
            throw CancellationError()
        }
        process = child
        do { try child.run() }
        catch {
            process = nil
            lock.unlock()
            throw DirectOKXError.transport("无法运行系统网络工具：\(error.localizedDescription)")
        }
        lock.unlock()
        // The parent's write ends must close so the reader sees EOF after child exit.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        let watchdog = DispatchWorkItem { [weak self] in self?.stop(.timeout) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let readers = DispatchGroup()
        for (handle, isError) in [(outputPipe.fileHandleForReading, false), (errorPipe.fileHandleForReading, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close(); readers.leave() }
                while true {
                    do {
                        guard let chunk = try handle.read(upToCount: 8_192), !chunk.isEmpty else { break }
                        if !self.append(chunk, isError: isError) {
                            self.stop(.tooLarge)
                            break
                        }
                    } catch { break }
                }
            }
        }
        child.waitUntilExit()
        watchdog.cancel()
        readers.wait()
        lock.lock()
        let stopReason = reason
        let output = ProcessOutput(status: child.terminationStatus, stdout: stdout, stderr: stderr)
        process = nil
        lock.unlock()
        switch stopReason {
        case .cancelled: throw CancellationError()
        case .timeout: throw DirectOKXError.timeout
        case .tooLarge: throw DirectOKXError.outputTooLarge
        case nil: return output
        }
    }

    private func append(_ data: Data, isError: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard totalBytes + data.count <= maxBytes else { return false }
        totalBytes += data.count
        if isError { stderr.append(data) } else { stdout.append(data) }
        return true
    }
}
