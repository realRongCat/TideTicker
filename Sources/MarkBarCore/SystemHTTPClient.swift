import Foundation

/// Uses the operating system's normal routing, DNS and proxy/SOCKS settings.
/// Production configuration leaves proxy policy untouched and never performs DoH.
actor SystemHTTPClient: HTTPTransport {
    private let configuration: URLSessionConfiguration
    private let deadline: TimeInterval
    private var session: SystemHTTPSession?
    private var requests: [UUID: SystemHTTPRequest] = [:]
    private var generation: UInt64 = 0

    init(configuration: URLSessionConfiguration? = nil, deadline: TimeInterval = 12) {
        self.configuration = (configuration?.copy() as? URLSessionConfiguration) ?? Self.defaultConfiguration()
        self.deadline = deadline.isFinite && deadline > 0 ? min(deadline, 12) : 12
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // nil is Apple's documented default: use the macOS system proxy settings.
        // No explicit proxy dictionary, PAC parsing or proxy credentials are copied.
        configuration.connectionProxyDictionary = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        return configuration
    }

    func get(hostname: String, path: String, query: [URLQueryItem] = [], maxBytes: Int = 65_536) async throws -> Data {
        try Task.checkCancellation()
        let url = try HTTPTransportRequest.url(hostname: hostname, path: path, query: query, maxBytes: maxBytes)
        let currentSession: SystemHTTPSession
        if let session { currentSession = session }
        else {
            currentSession = SystemHTTPSession(configuration: configuration)
            session = currentSession
        }
        let requestGeneration = generation
        let id = UUID()
        let transfer = SystemHTTPRequest(maxBytes: maxBytes, deadline: deadline)
        requests[id] = transfer
        defer { requests.removeValue(forKey: id) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: deadline)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let data = try await transfer.run(request, using: currentSession)
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            return data
        } onCancel: {
            transfer.cancel()
        }
    }

    func cancelAll() async { retireSession() }

    /// Dropping our session discards its connections and private transient caches.
    /// The replacement inherits current system settings; other apps are untouched.
    func invalidateNetworkCache() async { retireSession() }

    private func retireSession() {
        generation &+= 1
        let oldRequests = Array(requests.values)
        requests.removeAll()
        let oldSession = session
        session = nil
        // No suspension between detaching old state and cancelling it. New calls
        // get a new session and cannot be cancelled by callbacks from this one.
        oldRequests.forEach { $0.cancel() }
        oldSession?.invalidate()
    }

    deinit { session?.invalidate() }
}

enum SystemNetworkError: LocalizedError, Sendable {
    case timeout
    case dns
    case proxy
    case tls
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "系统网络请求超时"
        case .dns: return "系统 DNS 解析失败"
        case .proxy: return "系统代理连接失败"
        case .tls: return "系统网络 TLS 校验失败"
        case .transport(let message): return "系统网络请求失败：\(message)"
        }
    }
}

private final class SystemHTTPSession: @unchecked Sendable {
    let delegate: SystemHTTPSessionDelegate
    let session: URLSession

    init(configuration: URLSessionConfiguration) {
        delegate = SystemHTTPSessionDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func invalidate() { session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }
}

/// One registry per URLSession. Task identifiers from a retired session can never
/// collide with identifiers from its replacement session.
final class SystemHTTPSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: SystemHTTPRequest] = [:]

    fileprivate func register(_ transfer: SystemHTTPRequest, for task: URLSessionTask) {
        lock.lock()
        transfers[task.taskIdentifier] = transfer
        lock.unlock()
    }

    private func transfer(for task: URLSessionTask, remove: Bool = false) -> SystemHTTPRequest? {
        lock.lock()
        defer { lock.unlock() }
        if remove { return transfers.removeValue(forKey: task.taskIdentifier) }
        return transfers[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let accepted = transfer(for: dataTask)?.receive(response) ?? false
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(for: dataTask)?.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer(for: task, remove: true)?.finish(error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Match the direct transport: no redirects to different endpoints,
        // regions, or origins, even when the redirect target would be HTTPS.
        completionHandler(nil)
    }
}

private final class SystemHTTPRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private let deadline: TimeInterval
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var watchdog: DispatchWorkItem?
    private var data = Data()
    private var validatedResponse = false
    private var completed = false
    private var terminalError: Error?

    init(maxBytes: Int, deadline: TimeInterval) {
        self.maxBytes = maxBytes
        self.deadline = deadline
    }

    func run(_ request: URLRequest, using holder: SystemHTTPSession) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if completed {
                let error = terminalError ?? CancellationError()
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            self.continuation = continuation
            let task = holder.session.dataTask(with: request)
            self.task = task
            holder.delegate.register(self, for: task)
            let watchdog = DispatchWorkItem { [weak self] in self?.finish(error: SystemNetworkError.timeout) }
            self.watchdog = watchdog
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline, execute: watchdog)
            task.resume()
            lock.unlock()
        }
    }

    func cancel() { finish(error: CancellationError()) }

    func receive(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else {
            finish(error: DirectNetworkError.invalidHTTPResponse)
            return false
        }
        guard response.statusCode == 200 else {
            finish(error: DirectNetworkError.httpStatus(response.statusCode))
            return false
        }
        guard response.expectedContentLength < 0 || response.expectedContentLength <= Int64(maxBytes) else {
            finish(error: DirectNetworkError.outputTooLarge)
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        validatedResponse = true
        return true
    }

    func receive(_ chunk: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        guard chunk.count <= maxBytes - data.count else {
            lock.unlock()
            finish(error: DirectNetworkError.outputTooLarge)
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func finish(error originalError: Error?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let error: Error?
        if let urlError = originalError as? URLError {
            switch urlError.code {
            case .cancelled: error = CancellationError()
            case .timedOut: error = SystemNetworkError.timeout
            case .cannotFindHost, .dnsLookupFailed: error = SystemNetworkError.dns
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired: error = SystemNetworkError.tls
            default:
                let detail = urlError.localizedDescription
                let lowered = detail.lowercased()
                error = lowered.contains("proxy") || lowered.contains("socks") || lowered.contains("pac")
                    ? SystemNetworkError.proxy
                    : SystemNetworkError.transport(detail)
            }
        } else if let originalError { error = originalError }
        else if !validatedResponse { error = DirectNetworkError.invalidHTTPResponse }
        else { error = nil }
        terminalError = error
        let continuation = continuation
        self.continuation = nil
        let task = task
        self.task = nil
        let watchdog = watchdog
        self.watchdog = nil
        let result: Result<Data, Error> = error.map(Result.failure) ?? .success(data)
        data = Data()
        lock.unlock()
        watchdog?.cancel()
        if error != nil { task?.cancel() }
        continuation?.resume(with: result)
    }
}
