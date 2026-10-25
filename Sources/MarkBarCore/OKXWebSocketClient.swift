import Foundation

actor OKXWebSocketClient {
    private static let endpoint = URL(string: "wss://ws.okx.com:8443/ws/v5/public")!
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var runner: Task<Void, Never>?

    init(configuration: URLSessionConfiguration? = nil) {
        let configuration = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.connectionProxyDictionary = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 86_400
        session = URLSession(configuration: configuration)
    }

    func stream(contracts: [Contract]) -> AsyncThrowingStream<MainQuoteStreamEvent, Error> {
        cancelCurrent()
        let lookup = Dictionary(uniqueKeysWithValues: contracts.map { ($0.instrumentID, $0) })
        return AsyncThrowingStream { continuation in
            let socket = session.webSocketTask(with: Self.endpoint)
            self.socket = socket
            self.runner = Task { [weak self] in
                guard let self else { return }
                await self.run(socket: socket, contracts: contracts, lookup: lookup,
                               continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.cancel(socket: socket) }
            }
        }
    }

    func cancelAll() {
        cancelCurrent()
    }

    private func cancelCurrent() {
        runner?.cancel()
        runner = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func cancel(socket expected: URLSessionWebSocketTask) {
        guard socket === expected else {
            expected.cancel(with: .goingAway, reason: nil)
            return
        }
        cancelCurrent()
    }

    private func run(socket: URLSessionWebSocketTask, contracts: [Contract],
                     lookup: [String: Contract],
                     continuation: AsyncThrowingStream<MainQuoteStreamEvent, Error>.Continuation) async {
        socket.resume()
        let heartbeat = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                try Task.checkCancellation()
                try await socket.send(.string("ping"))
            }
        }
        defer {
            heartbeat.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            if self.socket === socket {
                self.socket = nil
                runner = nil
            }
        }
        do {
            let arguments = contracts.map { contract in
                ["channel": contract.marketKind == .spot ? "tickers" : "mark-price",
                 "instId": contract.instrumentID]
            }
            let payload = try JSONSerialization.data(withJSONObject: ["op": "subscribe", "args": arguments])
            guard let text = String(data: payload, encoding: .utf8) else {
                throw MarketDataError.malformed
            }
            try await socket.send(.string(text))
            while !Task.isCancelled {
                let message = try await receiveNext(from: socket)
                let data: Data
                switch message {
                case .string(let value):
                    if value == "pong" { continue }
                    guard let value = value.data(using: .utf8) else { throw MarketDataError.malformed }
                    data = value
                case .data(let value): data = value
                @unknown default: throw MarketDataError.malformed
                }
                guard data.count <= 1_048_576 else { throw DirectNetworkError.outputTooLarge }
                for event in try OKXWebSocketParser.events(data, contracts: lookup, receivedAt: Date()) {
                    continuation.yield(event)
                }
            }
            continuation.finish(throwing: CancellationError())
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func receiveNext(from socket: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: 35_000_000_000)
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return result
        }
    }

    deinit { session.invalidateAndCancel() }
}

enum OKXWebSocketParser {
    static func events(_ data: Data, contracts: [String: Contract],
                       receivedAt: Date) throws -> [MainQuoteStreamEvent] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MarketDataError.malformed
        }
        if let event = object["event"] as? String {
            let message = object["msg"] as? String ?? event
            if let argument = object["arg"] as? [String: Any],
               let instrumentID = argument["instId"] as? String,
               let contract = contracts[instrumentID] {
                if event == "subscribe" { return [.subscribed(contract)] }
                if event == "error" { return [.subscriptionFailed(contract, message)] }
            }
            if event == "subscribe" { return [] }
            throw MarketProviderError(exchange: .okx, reason: "WebSocket：\(message)")
        }
        guard let argument = object["arg"] as? [String: Any],
              let channel = argument["channel"] as? String,
              let rows = object["data"] as? [[String: Any]] else {
            throw MarketDataError.malformed
        }
        return try rows.map { row in
            guard let instrumentID = row["instId"] as? String,
                  let contract = contracts[instrumentID],
                  let timestamp = row["ts"] as? String else { throw MarketDataError.wrongInstrument }
            let expectedChannel = contract.marketKind == .spot ? "tickers" : "mark-price"
            guard channel == expectedChannel else { throw MarketDataError.wrongInstrument }
            let price = contract.priceKind == .last ? row["last"] as? String : row["markPx"] as? String
            guard let price else { throw MarketDataError.invalidPrice }
            return .quote(try MarketNumber.quote(contract: contract, price: price,
                                                 milliseconds: timestamp, now: receivedAt))
        }
    }

    static func quotes(_ data: Data, contracts: [String: Contract],
                       receivedAt: Date) throws -> [MarkQuote] {
        try events(data, contracts: contracts, receivedAt: receivedAt).compactMap { event in
            guard case .quote(let quote) = event else { return nil }
            return quote
        }
    }
}
