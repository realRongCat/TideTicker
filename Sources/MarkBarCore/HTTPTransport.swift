import Foundation

protocol HTTPTransport: Sendable {
    func get(hostname: String, path: String, query: [URLQueryItem], maxBytes: Int) async throws -> Data
    func cancelAll() async
    func invalidateNetworkCache() async
}

enum HTTPTransportFactory {
    static func make(mode: NetworkMode = .system) -> any HTTPTransport {
        switch mode {
        case .system: return SystemHTTPClient()
        case .physicalDirect: return PhysicalHTTPClient()
        }
    }
}

enum HTTPTransportRequest {
    static func url(hostname: String, path: String, query: [URLQueryItem], maxBytes: Int) throws -> URL {
        guard ["openapi.okx.com", "api.binance.com", "fapi.binance.com",
               "dapi.binance.com", "api.bybit.com"].contains(hostname),
              path.hasPrefix("/"), maxBytes > 0, maxBytes <= 4_194_304 else {
            throw DirectNetworkError.invalidHTTPResponse
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = hostname
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw DirectNetworkError.invalidHTTPResponse }
        return url
    }
}
