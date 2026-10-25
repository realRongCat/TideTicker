import Foundation
@preconcurrency import Network

enum KindleHTTPServerState: Sendable, Equatable {
    case starting
    case ready(port: UInt16)
    case failed(String)
    case stopped
}

private final class KindleHTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    private let lock = NSLock()
    private var completed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func claimCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

final class KindleHTTPServer: @unchecked Sendable {
    typealias StateHandler = @Sendable (KindleHTTPServerState) -> Void

    private let queue = DispatchQueue(label: "com.xlogic.TideTicker.kindle-http", qos: .utility)
    private let lock = NSLock()
    private var listener: NWListener?
    private var token = ""
    private var indexHTML = Data()
    private var snapshot = Data("{}".utf8)
    private var snapshotETag = "\"empty\""
    private var activeConnections = 0
    private let maximumConnections = 8

    func start(port: UInt16, token: String, indexHTML: Data,
               stateHandler: @escaping StateHandler) throws {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "KindleHTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "端口无效"])
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: endpointPort)
        lock.lock()
        self.token = token
        self.indexHTML = indexHTML
        self.listener = listener
        lock.unlock()

        listener.stateUpdateHandler = { [weak listener] state in
            guard let listener else { return }
            switch state {
            case .setup, .waiting:
                stateHandler(.starting)
            case .ready:
                let actualPort = listener.port?.rawValue ?? port
                stateHandler(.ready(port: actualPort))
            case .failed(let error):
                stateHandler(.failed(error.localizedDescription))
            case .cancelled:
                stateHandler(.stopped)
            @unknown default:
                stateHandler(.failed("服务进入未知状态"))
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        stateHandler(.starting)
        listener.start(queue: queue)
    }

    func update(snapshot: Data) {
        let etag = "\"\(Self.fingerprint(snapshot))\""
        lock.lock()
        self.snapshot = snapshot
        snapshotETag = etag
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        lock.unlock()
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let allowed = activeConnections < maximumConnections
        if allowed { activeConnections += 1 }
        lock.unlock()
        guard allowed else {
            connection.cancel()
            return
        }
        let context = KindleHTTPConnection(connection)
        connection.start(queue: queue)
        receive(context, accumulated: Data())
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, context.claimCompletion() else { return }
            context.connection.cancel()
            self.releaseConnection()
        }
    }

    private func receive(_ context: KindleHTTPConnection, accumulated: Data) {
        let remaining = max(1, 8_192 - accumulated.count)
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            var request = accumulated
            if let content { request.append(content) }
            if request.count >= 8_192 {
                self.respond(context, status: 431, reason: "Request Header Fields Too Large",
                             headers: [:], body: Data())
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.handle(request, context: context)
            } else if isComplete || error != nil {
                self.respond(context, status: 400, reason: "Bad Request", headers: [:], body: Data())
            } else {
                self.receive(context, accumulated: request)
            }
        }
    }

    private func handle(_ data: Data, context: KindleHTTPConnection) {
        guard let request = String(data: data, encoding: .utf8) else {
            respond(context, status: 400, reason: "Bad Request", headers: [:], body: Data())
            return
        }
        let lines = request.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard parts.count == 3 else {
            respond(context, status: 400, reason: "Bad Request", headers: [:], body: Data())
            return
        }
        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else {
            respond(context, status: 405, reason: "Method Not Allowed",
                    headers: ["Allow": "GET, HEAD"], body: Data())
            return
        }
        let rawTarget = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(rawTarget)") else {
            respond(context, status: 400, reason: "Bad Request", headers: [:], body: Data())
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        lock.lock()
        let token = self.token
        let html = indexHTML
        let snapshot = self.snapshot
        let etag = snapshotETag
        lock.unlock()

        let root = "/k/\(token)"
        let path = components.path
        let isHead = method == "HEAD"
        if path == "/favicon.ico" {
            respond(context, status: 204, reason: "No Content", headers: securityHeaders(),
                    body: Data(), omitBody: true)
            return
        }
        if path == root || path == "\(root)/" || path == "\(root)/index.html" {
            respond(context, status: 200, reason: "OK", headers: securityHeaders(adding: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
            ]), body: html, omitBody: isHead)
            return
        }
        if path == "\(root)/api/v1/snapshot" {
            let queryETag = components.queryItems?.first(where: { $0.name == "etag" })?.value
            if headers["if-none-match"] == etag || queryETag == etag {
                respond(context, status: 304, reason: "Not Modified", headers: [
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "no-cache",
                    "ETag": etag,
                ], body: Data(), omitBody: true)
            } else {
                respond(context, status: 200, reason: "OK", headers: securityHeaders(adding: [
                    "Access-Control-Allow-Origin": "*",
                    "Content-Type": "application/json; charset=utf-8",
                    "Cache-Control": "no-cache",
                    "ETag": etag,
                ]), body: snapshot, omitBody: isHead)
            }
            return
        }
        if path == "\(root)/health" {
            let body = Data("{\"status\":\"ok\"}".utf8)
            respond(context, status: 200, reason: "OK", headers: securityHeaders(adding: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store",
            ]), body: body, omitBody: isHead)
            return
        }
        respond(context, status: 404, reason: "Not Found", headers: securityHeaders(), body: Data())
    }

    private func securityHeaders(adding extra: [String: String] = [:]) -> [String: String] {
        var headers = [
            "Content-Security-Policy": "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY",
        ]
        for (key, value) in extra { headers[key] = value }
        return headers
    }

    private func respond(_ context: KindleHTTPConnection, status: Int, reason: String,
                         headers: [String: String], body: Data, omitBody: Bool = false) {
        guard context.claimCompletion() else { return }
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for key in allHeaders.keys.sorted() {
            head += "\(key): \(allHeaders[key]!)\r\n"
        }
        head += "\r\n"
        var response = Data(head.utf8)
        if !omitBody { response.append(body) }
        context.connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            context.connection.cancel()
            self?.releaseConnection()
        })
    }

    private func releaseConnection() {
        lock.lock()
        activeConnections = max(0, activeConnections - 1)
        lock.unlock()
    }

    private static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
