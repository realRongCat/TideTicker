import Foundation
import MarkBarCore

@main
struct Probe {
    struct Sample: Sendable {
        let contract: Contract
        let quote: MarkQuote?
        let error: String?
        let requestSeconds: TimeInterval
    }

    static func main() async {
        let arguments = CommandLine.arguments
        let networkIndex = arguments.firstIndex(of: "--network")
        let networkValue = networkIndex.flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        guard let networkMode = NetworkMode(rawValue: networkValue ?? (networkIndex == nil ? "system" : "")) else {
            emit(["success": false, "error": "--network 必须为 system 或 physicalDirect"])
            exit(2)
        }
        let client = MarketDataClient(networkMode: networkMode)
        let requestedRounds = arguments.firstIndex(of: "--rounds").flatMap { index in
            index + 1 < arguments.count ? Int(arguments[index + 1]) : nil
        } ?? 1
        let rounds = max(1, min(requestedRounds, 6))
        var failures = 0
        var book = QuoteBook()
        let contracts: [Contract]
        if arguments.contains("--all-markets") {
            do {
                let catalogue = try await client.instruments(for: .okx)
                contracts = MarketKind.allCases.compactMap { kind in
                    catalogue.first { $0.marketKind == kind && $0.symbol == "BTC" }
                        ?? catalogue.first { $0.marketKind == kind }
                }
                guard contracts.count == MarketKind.allCases.count else {
                    emit(["success": false, "error": "OKX 官方目录未返回全部三类市场"])
                    exit(1)
                }
            } catch {
                emit(["success": false, "error": error.localizedDescription])
                exit(1)
            }
        } else {
            contracts = Contract.allCases
        }
        for round in 1...rounds {
            await withTaskGroup(of: Sample.self) { group in
                for contract in contracts {
                    group.addTask {
                        let started = Date()
                        do {
                            let quote = try await client.fetch(contract)
                            return Sample(contract: contract, quote: quote, error: nil,
                                          requestSeconds: Date().timeIntervalSince(started))
                        } catch {
                            return Sample(contract: contract, quote: nil,
                                          error: error.localizedDescription,
                                          requestSeconds: Date().timeIntervalSince(started))
                        }
                    }
                }
                for await sample in group {
                    guard let quote = sample.quote else {
                        failures += 1
                        emit(["round": round, "networkMode": networkMode.rawValue, "success": false, "fetchSuccess": false,
                              "instrumentID": sample.contract.instrumentID,
                              "error": sample.error ?? "未知错误"])
                        continue
                    }
                    let previous = book.entry(for: sample.contract).quote
                    let regressed = previous.map { quote.dataTime < $0.dataTime } ?? false
                    let advanced = book.apply(quote)
                    let fresh = !book.entry(for: sample.contract).isStale(at: Date())
                    let success = fresh && !regressed
                    if !success { failures += 1 }
                    emit([
                        "round": round, "networkMode": networkMode.rawValue, "success": success, "fetchSuccess": true,
                        "fresh": fresh, "timestampAdvanced": advanced,
                        "timestampRegressed": regressed,
                        "instrumentID": sample.contract.instrumentID,
                        "price": NSDecimalNumber(decimal: quote.price).stringValue,
                        "marketKind": sample.contract.marketKind.rawValue,
                        "priceKind": sample.contract.priceKind.rawValue,
                        "quoteCurrency": sample.contract.quoteCurrency,
                        "dataTime": ISO8601DateFormatter().string(from: quote.dataTime),
                        "receivedAt": ISO8601DateFormatter().string(from: quote.receivedAt),
                        "dataAgeSeconds": quote.receivedAt.timeIntervalSince(quote.dataTime),
                        "requestSeconds": sample.requestSeconds
                    ])
                }
            }
            if round < rounds { try? await Task.sleep(for: .seconds(5)) }
        }
        await client.cancelAll()
        if failures > 0 { exit(1) }
    }

    static func emit(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}
