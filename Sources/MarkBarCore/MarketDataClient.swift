import Foundation

public struct MarketProviderError: LocalizedError, Sendable {
    public let exchange: Exchange
    public let reason: String
    public let diagnosticCategory: ConnectionDiagnosticErrorCategory?
    public init(exchange: Exchange, reason: String,
                diagnosticCategory: ConnectionDiagnosticErrorCategory? = nil) {
        self.exchange = exchange
        self.reason = reason
        self.diagnosticCategory = diagnosticCategory
    }
    public var errorDescription: String? { "\(exchange.title)：\(reason)" }
}

/// Public REST market data only. A client's transport mode is fixed at creation;
/// switching providers never changes its network route or the price basis.
public actor MarketDataClient {
    private struct CatalogRequest {
        let id: UUID
        let generation: UInt64
        let task: Task<[Contract], Error>
    }
    private let http: any HTTPTransport
    private let catalogLoader: (@Sendable (Exchange) async throws -> [Contract])?
    private var catalog: [Exchange: (expiresAt: Date, contracts: [Contract])] = [:]
    private var catalogTasks: [Exchange: CatalogRequest] = [:]
    private var catalogGeneration: UInt64 = 0

    public init(networkMode: NetworkMode = .system) {
        http = HTTPTransportFactory.make(mode: networkMode)
        catalogLoader = nil
    }

    // Keep catalog lifecycle tests independent of external network availability.
    init(catalogLoader: @escaping @Sendable (Exchange) async throws -> [Contract]) {
        http = HTTPTransportFactory.make()
        self.catalogLoader = catalogLoader
    }

    init(transport: any HTTPTransport) {
        http = transport
        catalogLoader = nil
    }

    public func invalidateNetworkCache() async { await http.invalidateNetworkCache() }
    public func cancelAll() async {
        catalogGeneration &+= 1
        let cancelledRequests = Array(catalogTasks.values)
        catalogTasks.removeAll()
        cancelledRequests.forEach { $0.task.cancel() }
        await http.cancelAll()
    }

    /// A forced refresh bypasses the completed cache, while sharing an already
    /// running request for the same exchange. A failed refresh retains the last
    /// verified cache until its original expiry; it never renews that expiry.
    public func instruments(for exchange: Exchange, forceReload: Bool = false) async throws -> [Contract] {
        try Task.checkCancellation()
        if !forceReload, let cached = catalog[exchange], cached.expiresAt > Date() { return cached.contracts }
        let request: CatalogRequest
        let ownsRequest: Bool
        if let active = catalogTasks[exchange] {
            request = active
            ownsRequest = false
        } else {
            let task = Task { try await self.loadInstruments(for: exchange) }
            request = CatalogRequest(id: UUID(), generation: catalogGeneration, task: task)
            catalogTasks[exchange] = request
            ownsRequest = true
        }
        defer {
            // cancelAll can clear this slot and a later caller can create a new
            // request before this waiter resumes. Never remove that newer task.
            if ownsRequest, catalogTasks[exchange]?.id == request.id {
                catalogTasks.removeValue(forKey: exchange)
            }
        }
        do {
            let contracts = try await request.task.value
            guard request.generation == catalogGeneration else { throw CancellationError() }
            if ownsRequest, catalogTasks[exchange]?.id == request.id {
                catalog[exchange] = (Date().addingTimeInterval(300), contracts)
            }
            try Task.checkCancellation()
            return contracts
        } catch is CancellationError { throw CancellationError() }
        catch { throw contextual(error, exchange: exchange) }
    }

    public func fetch(_ contract: Contract) async throws -> MarkQuote {
        do {
            try await validateListed(contract)
            let data: Data
            switch contract.exchange {
            case .okx:
                if contract.marketKind == .spot {
                    data = try await get(.okx, market: .spot, "/api/v5/market/ticker", ["instId": contract.instrumentID])
                    return try OKXSpotResponseParser.quote(data, contract: contract, receivedAt: Date())
                }
                data = try await get(.okx, market: contract.marketKind, "/api/v5/public/mark-price", ["instType": "SWAP", "instId": contract.instrumentID])
                return try OKXResponseParser.parse(data, contract: contract, receivedAt: Date())
            case .binance:
                switch contract.marketKind {
                case .spot:
                    data = try await get(.binance, market: .spot, "/api/v3/ticker/24hr", ["symbol": contract.instrumentID])
                    return try BinanceResponseParser.spot(data, contract: contract, receivedAt: Date())
                case .linearPerpetual:
                    data = try await get(.binance, market: .linearPerpetual, "/fapi/v1/premiumIndex", ["symbol": contract.instrumentID])
                case .inversePerpetual:
                    data = try await get(.binance, market: .inversePerpetual, "/dapi/v1/premiumIndex", ["symbol": contract.instrumentID])
                }
                return try BinanceResponseParser.mark(data, contract: contract, receivedAt: Date())
            case .bybit:
                data = try await get(.bybit, market: contract.marketKind, "/v5/market/tickers",
                                     ["category": contract.marketKind.bybitCategory, "symbol": contract.instrumentID])
                return try BybitResponseParser.quote(data, contract: contract, receivedAt: Date())
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw contextual(error, exchange: contract.exchange) }
    }

    public func details(for contract: Contract) async throws -> MarketDetails {
        do {
            try await validateListed(contract)
            switch contract.exchange {
            case .okx:
                if contract.marketKind == .spot {
                    let ticker = try await get(.okx, market: .spot, "/api/v5/market/ticker", ["instId": contract.instrumentID])
                    return try OKXSupplementParser.spot(ticker: ticker, contract: contract, now: Date())
                }
                async let ticker = get(.okx, market: contract.marketKind, "/api/v5/market/ticker", ["instId": contract.instrumentID])
                async let funding = get(.okx, market: contract.marketKind, "/api/v5/public/funding-rate", ["instId": contract.instrumentID])
                return try await OKXSupplementParser.details(ticker: ticker, funding: funding, contract: contract, now: Date())
            case .binance:
                if contract.marketKind == .spot {
                    let ticker = try await get(.binance, market: .spot, "/api/v3/ticker/24hr", ["symbol": contract.instrumentID])
                    return try BinanceResponseParser.spotDetails(ticker, contract: contract, now: Date())
                }
                let prefix = contract.marketKind == .linearPerpetual ? "/fapi" : "/dapi"
                async let ticker = get(.binance, market: contract.marketKind, "\(prefix)/v1/ticker/24hr", ["symbol": contract.instrumentID])
                async let funding = get(.binance, market: contract.marketKind, "\(prefix)/v1/premiumIndex", ["symbol": contract.instrumentID])
                return try await BinanceResponseParser.details(ticker: ticker, funding: funding, contract: contract, now: Date())
            case .bybit:
                let data = try await get(.bybit, market: contract.marketKind, "/v5/market/tickers",
                                         ["category": contract.marketKind.bybitCategory, "symbol": contract.instrumentID])
                return try BybitResponseParser.details(data, contract: contract, now: Date())
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw contextual(error, exchange: contract.exchange) }
    }

    public func connectionDiagnostics(exchange: Exchange, networkMode: NetworkMode,
                                      appVersion: String, preferredContract: Contract?) async throws -> ConnectionDiagnosticReport {
        let startedAt = Date()
        var steps: [ConnectionDiagnosticStep] = []
        let catalogueStartedAt = Date()
        let contracts: [Contract]
        do {
            contracts = try await instruments(for: exchange, forceReload: true)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let category = ConnectionDiagnosticErrorCategory.classify(error)
            steps.append(ConnectionDiagnosticStep(
                stage: .catalogue,
                hostnames: exchange.diagnosticCatalogueHostnames,
                market: "现货、USDT 永续、币本位永续",
                duration: Date().timeIntervalSince(catalogueStartedAt),
                succeeded: false,
                detail: category.title,
                errorCategory: category
            ))
            return ConnectionDiagnosticReport(appVersion: appVersion, exchange: exchange,
                networkMode: networkMode, startedAt: startedAt,
                duration: Date().timeIntervalSince(startedAt), steps: steps)
        }

        guard !contracts.isEmpty else {
            let category = ConnectionDiagnosticErrorCategory.business
            steps.append(ConnectionDiagnosticStep(
                stage: .catalogue,
                hostnames: exchange.diagnosticCatalogueHostnames,
                market: "现货、USDT 永续、币本位永续",
                duration: Date().timeIntervalSince(catalogueStartedAt),
                succeeded: false,
                detail: "交易所没有返回可用品种",
                errorCategory: category
            ))
            return ConnectionDiagnosticReport(appVersion: appVersion, exchange: exchange,
                networkMode: networkMode, startedAt: startedAt,
                duration: Date().timeIntervalSince(startedAt), steps: steps)
        }

        steps.append(ConnectionDiagnosticStep(
            stage: .catalogue,
            hostnames: exchange.diagnosticCatalogueHostnames,
            market: "现货、USDT 永续、币本位永续",
            duration: Date().timeIntervalSince(catalogueStartedAt),
            succeeded: true,
            detail: "已读取 \(contracts.count) 个可用品种"
        ))

        let target = preferredContract.flatMap { preferred in
            contracts.first { $0.id == preferred.id }
        } ?? contracts[0]
        let quoteStartedAt = Date()
        do {
            let quote = try await fetch(target)
            try Task.checkCancellation()
            steps.append(ConnectionDiagnosticStep(
                stage: .quote,
                hostnames: [exchange.diagnosticQuoteHostname(for: target.marketKind)],
                market: target.marketKind.title,
                duration: Date().timeIntervalSince(quoteStartedAt),
                succeeded: true,
                detail: "\(quote.contract.displayTitle) · \(quote.contract.priceTitle) \(PriceFormatting.exact(quote.price)) \(quote.contract.quoteCurrency)"
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let category = ConnectionDiagnosticErrorCategory.classify(error)
            steps.append(ConnectionDiagnosticStep(
                stage: .quote,
                hostnames: [exchange.diagnosticQuoteHostname(for: target.marketKind)],
                market: target.marketKind.title,
                duration: Date().timeIntervalSince(quoteStartedAt),
                succeeded: false,
                detail: category.title,
                errorCategory: category
            ))
        }
        return ConnectionDiagnosticReport(appVersion: appVersion, exchange: exchange,
            networkMode: networkMode, startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt), steps: steps)
    }

    private func validateListed(_ contract: Contract) async throws {
        let listed = try await instruments(for: contract.exchange)
        try Task.checkCancellation()
        guard listed.contains(contract) else {
            throw MarketProviderError(exchange: contract.exchange, reason: "该品种不在当前可用的官方市场目录中")
        }
    }

    private func loadInstruments(for exchange: Exchange) async throws -> [Contract] {
        if let catalogLoader { return try await catalogLoader(exchange) }
        switch exchange {
        case .okx:
            async let spot = get(.okx, market: .spot, "/api/v5/public/instruments", ["instType": "SPOT"], maxBytes: 4_194_304)
            async let swaps = get(.okx, market: .linearPerpetual, "/api/v5/public/instruments", ["instType": "SWAP"], maxBytes: 4_194_304)
            return try InstrumentCatalogParser.finish(
                InstrumentCatalogParser.okxSpot(await spot) + InstrumentCatalogParser.okxPerpetuals(await swaps)
            )
        case .binance:
            async let spot = get(.binance, market: .spot, "/api/v3/exchangeInfo", [:], maxBytes: 4_194_304)
            async let linear = get(.binance, market: .linearPerpetual, "/fapi/v1/exchangeInfo", [:], maxBytes: 4_194_304)
            async let inverse = get(.binance, market: .inversePerpetual, "/dapi/v1/exchangeInfo", [:], maxBytes: 4_194_304)
            return try InstrumentCatalogParser.finish(
                InstrumentCatalogParser.binanceSpot(await spot)
                + InstrumentCatalogParser.binanceLinear(await linear)
                + InstrumentCatalogParser.binanceInverse(await inverse)
            )
        case .bybit:
            async let spot = loadBybit(kind: .spot)
            async let linear = loadBybit(kind: .linearPerpetual)
            async let inverse = loadBybit(kind: .inversePerpetual)
            return try InstrumentCatalogParser.finish(await spot + linear + inverse)
        }
    }

    private func loadBybit(kind: MarketKind) async throws -> [Contract] {
        var contracts: [Contract] = []
        var cursor: String?
        var seenCursors = Set<String>()
        for _ in 0..<10 {
            var query = ["category": kind.bybitCategory, "status": "Trading", "limit": "1000"]
            if let cursor { query["cursor"] = cursor }
            let data = try await get(.bybit, market: kind, "/v5/market/instruments-info", query, maxBytes: 4_194_304)
            let page = try InstrumentCatalogParser.bybitPage(data, marketKind: kind)
            contracts += page.contracts
            guard contracts.count <= 10_000 else { throw MarketDataError.malformed }
            guard let next = page.nextCursor, !next.isEmpty else { return contracts }
            guard next.utf8.count <= 4_096, seenCursors.insert(next).inserted else { throw MarketDataError.malformed }
            cursor = next
        }
        throw MarketProviderError(exchange: .bybit, reason: "\(kind.title)目录超过分页上限，未使用不完整结果")
    }

    private func get(_ exchange: Exchange, market: MarketKind, _ path: String,
                     _ query: [String: String], maxBytes: Int = 65_536) async throws -> Data {
        let hostname: String
        switch exchange {
        case .okx: hostname = "openapi.okx.com"
        case .binance:
            switch market {
            case .spot: hostname = "api.binance.com"
            case .linearPerpetual: hostname = "fapi.binance.com"
            case .inversePerpetual: hostname = "dapi.binance.com"
            }
        case .bybit: hostname = "api.bybit.com"
        }
        return try await http.get(hostname: hostname, path: path,
                                  query: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) },
                                  maxBytes: maxBytes)
    }

    private func contextual(_ error: Error, exchange: Exchange) -> MarketProviderError {
        (error as? MarketProviderError) ?? MarketProviderError(
            exchange: exchange,
            reason: error.localizedDescription,
            diagnosticCategory: ConnectionDiagnosticErrorCategory.classify(error)
        )
    }
}

private extension MarketKind {
    var bybitCategory: String {
        switch self {
        case .spot: return "spot"
        case .linearPerpetual: return "linear"
        case .inversePerpetual: return "inverse"
        }
    }
}

enum MarketNumber {
    static func decimal(_ string: String?) -> Decimal? {
        guard let string,
              string.range(of: #"\A-?(0|[1-9][0-9]{0,17})(\.[0-9]{1,18})?\z"#, options: .regularExpression) != nil,
              let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }
    static func positive(_ string: String?) -> Decimal? {
        guard let number = decimal(string), number > 0 else { return nil }
        return number
    }
    static func milliseconds(_ string: String?) -> Date? {
        guard let string, string.count == 13, string.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int64(string), value >= 1_577_836_800_000 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 1_000)
    }
    static func quote(contract: Contract, price: String, milliseconds: String, now: Date) throws -> MarkQuote {
        guard let price = positive(price) else { throw MarketDataError.invalidPrice }
        guard let time = self.milliseconds(milliseconds), time.timeIntervalSince(now) <= 30 else { throw MarketDataError.invalidTimestamp }
        guard now.timeIntervalSince(time) <= 60 else { throw MarketDataError.stale }
        return MarkQuote(contract: contract, price: price, dataTime: time, receivedAt: now)
    }
}

enum MarketJSON {
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw MarketDataError.malformed }
    }
}

struct OKXEnvelope<Row: Decodable>: Decodable {
    let code: String
    let data: [Row]?
    func rows() throws -> [Row] {
        guard code == "0" else { throw MarketDataError.rejected(code) }
        guard let data else { throw MarketDataError.malformed }
        return data
    }
}

struct BybitEnvelope<Row: Decodable>: Decodable {
    struct Result: Decodable {
        let category: String
        let list: [Row]
        let nextPageCursor: String?
    }
    let retCode: Int
    let result: Result?
    let time: Int64?
    func result(category: String) throws -> Result {
        guard retCode == 0 else { throw MarketDataError.rejected(String(retCode)) }
        guard let result, result.category == category else { throw MarketDataError.wrongInstrument }
        return result
    }
}

enum InstrumentCatalogParser {
    struct Page { let contracts: [Contract]; let nextCursor: String? }
    private struct OKXRow: Decodable {
        let instType: String
        let instId: String
        let ctType: String?
        let settleCcy: String?
        let ctValCcy: String?
        let baseCcy: String?
        let quoteCcy: String?
        let state: String
        let ruleType: String
    }
    private struct BinanceCatalog: Decodable { let symbols: [BinanceRow] }
    private struct BinanceRow: Decodable {
        let symbol: String
        let contractType: String?
        let status: String
        let baseAsset: String
        let quoteAsset: String
        let marginAsset: String?
        let isSpotTradingAllowed: Bool?
    }
    private struct BybitRow: Decodable {
        let symbol: String
        let contractType: String?
        let status: String
        let baseCoin: String
        let quoteCoin: String
        let settleCoin: String?
        let isPreListing: Bool?
    }

    // Compatibility entry points retained for focused parser tests.
    static func okx(_ data: Data) throws -> [Contract] {
        try finish(okxPerpetuals(data).filter { $0.marketKind == .linearPerpetual })
    }

    static func okxSpot(_ data: Data) throws -> [Contract] {
        let rows = try MarketJSON.decode(OKXEnvelope<OKXRow>.self, data).rows()
        return try finish(rows.compactMap { row in
            guard row.instType == "SPOT", row.state == "live", row.ruleType == "normal",
                  let base = row.baseCcy, validSymbol(base), row.quoteCcy == "USDT",
                  row.instId == "\(base)-USDT" else { return nil }
            return Contract(exchange: .okx, instrumentID: row.instId, symbol: base,
                            marketKind: .spot, quoteCurrency: "USDT",
                            settlementCurrency: "USDT", priceKind: .last)
        })
    }

    static func okxPerpetuals(_ data: Data) throws -> [Contract] {
        let rows = try MarketJSON.decode(OKXEnvelope<OKXRow>.self, data).rows()
        return try finish(rows.compactMap { row in
            guard row.instType == "SWAP", row.state == "live", row.ruleType == "normal" else { return nil }
            if row.ctType == "linear", row.settleCcy == "USDT", let base = row.ctValCcy,
               validSymbol(base), row.instId == "\(base)-USDT-SWAP" {
                return Contract(exchange: .okx, instrumentID: row.instId, symbol: base)
            }
            if row.ctType == "inverse", row.ctValCcy == "USD", let base = row.settleCcy,
               validSymbol(base), row.instId == "\(base)-USD-SWAP" {
                return Contract(exchange: .okx, instrumentID: row.instId, symbol: base,
                                marketKind: .inversePerpetual, quoteCurrency: "USD",
                                settlementCurrency: base, priceKind: .mark)
            }
            return nil
        })
    }

    static func binance(_ data: Data) throws -> [Contract] { try binanceLinear(data) }

    static func binanceSpot(_ data: Data) throws -> [Contract] {
        let catalog = try MarketJSON.decode(BinanceCatalog.self, data)
        return try finish(catalog.symbols.compactMap { row in
            guard row.status == "TRADING", row.quoteAsset == "USDT",
                  row.isSpotTradingAllowed != false, validSymbol(row.baseAsset),
                  row.symbol == "\(row.baseAsset)USDT" else { return nil }
            return Contract(exchange: .binance, instrumentID: row.symbol, symbol: row.baseAsset,
                            marketKind: .spot, quoteCurrency: "USDT",
                            settlementCurrency: "USDT", priceKind: .last)
        })
    }

    static func binanceLinear(_ data: Data) throws -> [Contract] {
        let catalog = try MarketJSON.decode(BinanceCatalog.self, data)
        return try finish(catalog.symbols.compactMap { row in
            guard row.contractType == "PERPETUAL", row.status == "TRADING", row.quoteAsset == "USDT",
                  row.marginAsset == "USDT", validSymbol(row.baseAsset), row.symbol == "\(row.baseAsset)USDT" else { return nil }
            return Contract(exchange: .binance, instrumentID: row.symbol, symbol: row.baseAsset)
        })
    }

    static func binanceInverse(_ data: Data) throws -> [Contract] {
        let catalog = try MarketJSON.decode(BinanceCatalog.self, data)
        return try finish(catalog.symbols.compactMap { row in
            guard row.contractType == "PERPETUAL", row.status == "TRADING", row.quoteAsset == "USD",
                  row.marginAsset == row.baseAsset, validSymbol(row.baseAsset),
                  row.symbol == "\(row.baseAsset)USD_PERP" else { return nil }
            return Contract(exchange: .binance, instrumentID: row.symbol, symbol: row.baseAsset,
                            marketKind: .inversePerpetual, quoteCurrency: "USD",
                            settlementCurrency: row.baseAsset, priceKind: .mark)
        })
    }

    static func bybitPage(_ data: Data, marketKind: MarketKind = .linearPerpetual) throws -> Page {
        let result = try MarketJSON.decode(BybitEnvelope<BybitRow>.self, data).result(category: marketKind.bybitCategory)
        let contracts: [Contract] = result.list.compactMap { row in
            guard row.status == "Trading", validSymbol(row.baseCoin), row.isPreListing != true else { return nil }
            switch marketKind {
            case .spot:
                guard row.quoteCoin == "USDT", row.symbol == "\(row.baseCoin)USDT" else { return nil }
                return Contract(exchange: .bybit, instrumentID: row.symbol, symbol: row.baseCoin,
                                marketKind: .spot, quoteCurrency: "USDT",
                                settlementCurrency: "USDT", priceKind: .last)
            case .linearPerpetual:
                guard row.contractType == "LinearPerpetual", row.quoteCoin == "USDT",
                      row.settleCoin == "USDT", row.symbol == "\(row.baseCoin)USDT" else { return nil }
                return Contract(exchange: .bybit, instrumentID: row.symbol, symbol: row.baseCoin)
            case .inversePerpetual:
                guard row.contractType == "InversePerpetual", row.quoteCoin == "USD",
                      row.settleCoin == row.baseCoin, row.symbol == "\(row.baseCoin)USD" else { return nil }
                return Contract(exchange: .bybit, instrumentID: row.symbol, symbol: row.baseCoin,
                                marketKind: .inversePerpetual, quoteCurrency: "USD",
                                settlementCurrency: row.baseCoin, priceKind: .mark)
            }
        }
        return Page(contracts: contracts, nextCursor: result.nextPageCursor)
    }

    static func finish(_ contracts: [Contract]) throws -> [Contract] {
        guard !contracts.isEmpty, contracts.count <= 10_000 else { throw MarketDataError.malformed }
        return Array(Set(contracts)).sorted {
            let symbolOrder = $0.symbol.localizedStandardCompare($1.symbol)
            if symbolOrder != .orderedSame { return symbolOrder == .orderedAscending }
            if $0.marketKind != $1.marketKind { return $0.marketKind.sortOrder < $1.marketKind.sortOrder }
            return $0.instrumentID.localizedStandardCompare($1.instrumentID) == .orderedAscending
        }
    }

    private static func validSymbol(_ string: String) -> Bool {
        // Exchanges can list non-Latin asset symbols. Names remain display data;
        // URLComponents encodes their native instrument IDs as query parameters.
        !string.isEmpty && string.count <= 32 && string.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}

private extension MarketKind {
    var sortOrder: Int {
        switch self {
        case .spot: return 0
        case .linearPerpetual: return 1
        case .inversePerpetual: return 2
        }
    }
}

enum OKXSpotResponseParser {
    private struct Ticker: Decodable {
        let instType: String
        let instId: String
        let last: String
        let ts: String
    }

    static func quote(_ data: Data, contract: Contract, receivedAt: Date) throws -> MarkQuote {
        let rows = try MarketJSON.decode(OKXEnvelope<Ticker>.self, data).rows()
        guard contract.exchange == .okx, contract.marketKind == .spot, contract.priceKind == .last,
              rows.count == 1, let ticker = rows.first, ticker.instType == "SPOT",
              ticker.instId == contract.instrumentID else { throw MarketDataError.wrongInstrument }
        return try MarketNumber.quote(contract: contract, price: ticker.last,
                                      milliseconds: ticker.ts, now: receivedAt)
    }
}

enum OKXSupplementParser {
    private struct Ticker: Decodable {
        let instType: String; let instId: String
        let last: String; let open24h: String; let ts: String
    }
    private struct Funding: Decodable {
        let instType: String; let instId: String
        let fundingRate: String; let fundingTime: String; let nextFundingTime: String
        let ts: String
    }

    static func spot(ticker data: Data, contract: Contract, now: Date) throws -> MarketDetails {
        guard contract.exchange == .okx, contract.marketKind == .spot else { throw MarketDataError.wrongInstrument }
        let tickers = try MarketJSON.decode(OKXEnvelope<Ticker>.self, data).rows()
        guard tickers.count == 1, let ticker = tickers.first, ticker.instType == "SPOT",
              ticker.instId == contract.instrumentID else { throw MarketDataError.wrongInstrument }
        let last = MarketNumber.positive(ticker.last)
        let open = MarketNumber.positive(ticker.open24h)
        let change = last.flatMap { value in open.map { (value - $0) / $0 * 100 } }
        return MarketDetails(lastPrice: last, change24hPercent: change,
                             fundingRate: nil, nextFundingTime: nil, updatedAt: now)
    }

    static func details(ticker: Data, funding: Data, contract: Contract, now: Date) throws -> MarketDetails {
        guard contract.exchange == .okx, contract.marketKind.isPerpetual,
              contract.priceKind == .mark else { throw MarketDataError.wrongInstrument }
        let tickers = try MarketJSON.decode(OKXEnvelope<Ticker>.self, ticker).rows()
        let fundings = try MarketJSON.decode(OKXEnvelope<Funding>.self, funding).rows()
        guard tickers.count == 1, fundings.count == 1, let ticker = tickers.first, let funding = fundings.first,
              ticker.instType == "SWAP", funding.instType == "SWAP", ticker.instId == contract.instrumentID,
              funding.instId == contract.instrumentID else { throw MarketDataError.wrongInstrument }
        let last = MarketNumber.positive(ticker.last)
        let open = MarketNumber.positive(ticker.open24h)
        let change: Decimal? = last.flatMap { last in open.map { (last - $0) / $0 * 100 } }
        // OKX fundingTime belongs to fundingRate's current settlement cycle.
        // Its nextFundingTime is the following cycle; do not mislabel that as the next payment.
        let settlement = MarketNumber.milliseconds(funding.fundingTime)
        return MarketDetails(lastPrice: last, change24hPercent: change,
                             fundingRate: MarketNumber.decimal(funding.fundingRate),
                             nextFundingTime: settlement, updatedAt: now)
    }
}

enum BinanceResponseParser {
    private struct Premium: Decodable {
        let symbol: String; let markPrice: String; let time: Int64
        let lastFundingRate: String?; let nextFundingTime: Int64?
    }
    private struct Ticker: Decodable {
        let symbol: String; let lastPrice: String; let priceChangePercent: String
        let closeTime: Int64?
    }

    static func spot(_ data: Data, contract: Contract, receivedAt: Date) throws -> MarkQuote {
        let ticker = try MarketJSON.decode(Ticker.self, data)
        guard contract.exchange == .binance, contract.marketKind == .spot,
              contract.priceKind == .last, ticker.symbol == contract.instrumentID,
              let closeTime = ticker.closeTime else { throw MarketDataError.wrongInstrument }
        return try MarketNumber.quote(contract: contract, price: ticker.lastPrice,
                                      milliseconds: String(closeTime), now: receivedAt)
    }

    static func mark(_ data: Data, contract: Contract, receivedAt: Date) throws -> MarkQuote {
        let response = try MarketJSON.decode(Premium.self, data)
        guard contract.exchange == .binance, contract.marketKind.isPerpetual,
              contract.priceKind == .mark, response.symbol == contract.instrumentID else { throw MarketDataError.wrongInstrument }
        return try MarketNumber.quote(contract: contract, price: response.markPrice, milliseconds: String(response.time), now: receivedAt)
    }

    static func spotDetails(_ data: Data, contract: Contract, now: Date) throws -> MarketDetails {
        let ticker = try MarketJSON.decode(Ticker.self, data)
        guard contract.exchange == .binance, contract.marketKind == .spot,
              ticker.symbol == contract.instrumentID else { throw MarketDataError.wrongInstrument }
        return MarketDetails(lastPrice: MarketNumber.positive(ticker.lastPrice),
                             change24hPercent: MarketNumber.decimal(ticker.priceChangePercent),
                             fundingRate: nil, nextFundingTime: nil, updatedAt: now)
    }

    static func details(ticker: Data, funding: Data, contract: Contract, now: Date) throws -> MarketDetails {
        let ticker = try MarketJSON.decode(Ticker.self, ticker)
        let premium = try MarketJSON.decode(Premium.self, funding)
        guard contract.exchange == .binance, contract.marketKind.isPerpetual,
              ticker.symbol == contract.instrumentID, premium.symbol == contract.instrumentID else { throw MarketDataError.wrongInstrument }
        return MarketDetails(lastPrice: MarketNumber.positive(ticker.lastPrice),
                             change24hPercent: MarketNumber.decimal(ticker.priceChangePercent),
                             fundingRate: MarketNumber.decimal(premium.lastFundingRate),
                             nextFundingTime: MarketNumber.milliseconds(premium.nextFundingTime.map(String.init)), updatedAt: now)
    }
}

enum BybitResponseParser {
    private struct Ticker: Decodable {
        let symbol: String; let markPrice: String?
        let lastPrice: String?; let price24hPcnt: String?
        let fundingRate: String?; let nextFundingTime: String?
    }
    private static func response(_ data: Data, contract: Contract) throws -> (BybitEnvelope<Ticker>, Ticker) {
        let envelope = try MarketJSON.decode(BybitEnvelope<Ticker>.self, data)
        let result = try envelope.result(category: contract.marketKind.bybitCategory)
        guard contract.exchange == .bybit, result.list.count == 1, let ticker = result.list.first,
              ticker.symbol == contract.instrumentID else { throw MarketDataError.wrongInstrument }
        return (envelope, ticker)
    }

    static func quote(_ data: Data, contract: Contract, receivedAt: Date) throws -> MarkQuote {
        let (envelope, ticker) = try response(data, contract: contract)
        guard let serverTime = envelope.time else { throw MarketDataError.invalidTimestamp }
        // V5's top-level time is response server time, not a per-ticker calculation timestamp.
        let price = contract.priceKind == .mark ? ticker.markPrice : ticker.lastPrice
        guard let price else { throw MarketDataError.invalidPrice }
        return try MarketNumber.quote(contract: contract, price: price, milliseconds: String(serverTime), now: receivedAt)
    }

    static func mark(_ data: Data, contract: Contract, receivedAt: Date) throws -> MarkQuote {
        try quote(data, contract: contract, receivedAt: receivedAt)
    }
    static func details(_ data: Data, contract: Contract, now: Date) throws -> MarketDetails {
        let (_, ticker) = try response(data, contract: contract)
        return MarketDetails(lastPrice: MarketNumber.positive(ticker.lastPrice),
                             change24hPercent: MarketNumber.decimal(ticker.price24hPcnt).map { $0 * 100 },
                             fundingRate: MarketNumber.decimal(ticker.fundingRate),
                             nextFundingTime: MarketNumber.milliseconds(ticker.nextFundingTime), updatedAt: now)
    }
}
