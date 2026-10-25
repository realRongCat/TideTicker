import Foundation

public enum ConnectionDiagnosticStage: String, Sendable, Equatable {
    case catalogue
    case quote

    public var title: String {
        switch self {
        case .catalogue: return "市场目录"
        case .quote: return "代表报价"
        }
    }
}

public enum ConnectionDiagnosticErrorCategory: String, CaseIterable, Sendable, Equatable {
    case timeout
    case dns
    case physicalInterface
    case proxy
    case tls
    case http403
    case http451
    case http
    case responseTooLarge
    case parsing
    case business
    case cancelled
    case unknown

    public var title: String {
        switch self {
        case .timeout: return "连接超时"
        case .dns: return "DNS / DoH 解析失败"
        case .physicalInterface: return "物理网卡不可用"
        case .proxy: return "系统代理连接失败"
        case .tls: return "TLS 校验失败"
        case .http403: return "服务端拒绝访问（HTTP 403）"
        case .http451: return "地区或政策限制（HTTP 451）"
        case .http: return "HTTP 请求失败"
        case .responseTooLarge: return "响应超过大小限制"
        case .parsing: return "响应解析失败"
        case .business: return "交易所业务响应失败"
        case .cancelled: return "测试已取消"
        case .unknown: return "连接失败"
        }
    }

    public var recommendation: String {
        switch self {
        case .timeout:
            return "确认当前网络可访问该交易所官方接口后重试。"
        case .dns:
            return "系统网络请检查 macOS DNS；物理直连请确认物理 IPv4 与 DoH 可达。"
        case .physicalInterface:
            return "连接可用的 Wi-Fi 或有线网卡，或改用默认推荐的系统网络。"
        case .proxy:
            return "检查 macOS 代理、PAC 或 SOCKS 配置及其可达性。"
        case .tls:
            return "检查系统时间、证书链和代理的 TLS 处理后重试。"
        case .http403:
            return "当前出口被服务端拒绝。应用不会自动换端点或绕过限制。"
        case .http451:
            return "当前出口受服务政策限制。应用不会自动换地区端点或绕过限制。"
        case .http:
            return "稍后重试，并根据 HTTP 状态确认交易所服务是否可用。"
        case .responseTooLarge:
            return "响应异常增大，稍后重试；应用不会放宽安全大小限制。"
        case .parsing:
            return "交易所响应与预期格式不一致，请更新应用或稍后重试。"
        case .business:
            return "检查交易所服务状态和所选市场是否仍可用。"
        case .cancelled:
            return "设置已变化；请在当前来源与网络模式下重新测试。"
        case .unknown:
            return "检查网络与交易所服务状态后重试。"
        }
    }

    public static func classify(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let provider = error as? MarketProviderError,
           let category = provider.diagnosticCategory { return category }
        if let direct = error as? DirectNetworkError {
            switch direct {
            case .noPhysicalInterface, .noDirectRoute: return .physicalInterface
            case .dnsResolution: return .dns
            case .timeout: return .timeout
            case .outputTooLarge: return .responseTooLarge
            case .httpStatus(403): return .http403
            case .httpStatus(451): return .http451
            case .httpStatus, .invalidHTTPResponse: return .http
            case .transport(let detail):
                return Self.transportCategory(detail)
            }
        }
        if let system = error as? SystemNetworkError {
            switch system {
            case .timeout: return .timeout
            case .dns: return .dns
            case .proxy: return .proxy
            case .tls: return .tls
            case .transport(let detail): return Self.transportCategory(detail)
            }
        }
        if let market = error as? MarketDataError {
            switch market {
            case .rejected: return .business
            case .malformed, .wrongInstrument, .invalidPrice, .invalidTimestamp, .stale: return .parsing
            }
        }
        return .unknown
    }

    private static func transportCategory(_ detail: String) -> Self {
        let detail = detail.lowercased()
        if detail.contains("certificate") || detail.contains("ssl") || detail.contains("tls") { return .tls }
        if detail.contains("proxy") || detail.contains("socks") || detail.contains("pac") { return .proxy }
        if detail.contains("resolve") || detail.contains("dns") || detail.contains("host name") { return .dns }
        return .unknown
    }
}

public struct ConnectionDiagnosticStep: Sendable, Equatable, Identifiable {
    public let stage: ConnectionDiagnosticStage
    public let hostnames: [String]
    public let market: String
    public let duration: TimeInterval
    public let succeeded: Bool
    public let detail: String
    public let errorCategory: ConnectionDiagnosticErrorCategory?

    public var id: ConnectionDiagnosticStage { stage }

    public init(stage: ConnectionDiagnosticStage, hostnames: [String], market: String,
                duration: TimeInterval, succeeded: Bool, detail: String,
                errorCategory: ConnectionDiagnosticErrorCategory? = nil) {
        self.stage = stage
        self.hostnames = hostnames
        self.market = market
        self.duration = duration
        self.succeeded = succeeded
        self.detail = detail
        self.errorCategory = errorCategory
    }
}

public struct ConnectionDiagnosticReport: Sendable, Equatable {
    public let appVersion: String
    public let exchange: Exchange
    public let networkMode: NetworkMode
    public let startedAt: Date
    public let duration: TimeInterval
    public let steps: [ConnectionDiagnosticStep]

    public init(appVersion: String, exchange: Exchange, networkMode: NetworkMode,
                startedAt: Date, duration: TimeInterval, steps: [ConnectionDiagnosticStep]) {
        self.appVersion = appVersion
        self.exchange = exchange
        self.networkMode = networkMode
        self.startedAt = startedAt
        self.duration = duration
        self.steps = steps
    }

    public var succeeded: Bool {
        steps.count == 2 && steps.allSatisfy(\.succeeded)
    }

    public var recommendation: String {
        steps.compactMap(\.errorCategory).first?.recommendation
            ?? "目录与代表报价均已通过，可继续使用当前连接。"
    }

    public var copyText: String {
        let timestamp = ISO8601DateFormatter().string(from: startedAt)
        var lines = [
            "TideTicker 连接诊断",
            "应用版本：\(Self.redact(appVersion))",
            "测试时间：\(timestamp)",
            "行情来源：\(exchange.title)",
            "网络模式：\(networkMode.title)",
            "总耗时：\(Self.seconds(duration))",
            "结果：\(succeeded ? "通过" : "失败")",
        ]
        for step in steps {
            lines.append("")
            lines.append("[\(step.stage.title)] \(step.succeeded ? "通过" : "失败") · \(Self.seconds(step.duration))")
            lines.append("官方主机：\(step.hostnames.map(Self.redact).joined(separator: "、"))")
            lines.append("市场：\(Self.redact(step.market))")
            if let category = step.errorCategory { lines.append("错误类别：\(category.title)") }
            lines.append("详情：\(Self.redact(step.detail))")
        }
        lines.append("")
        lines.append("建议：\(recommendation)")
        return lines.joined(separator: "\n")
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2f 秒", max(0, value.isFinite ? value : 0))
    }

    private static func redact(_ value: String) -> String {
        var result = value
        let patterns = [
            #"(?i)(?:/Users|/home|/private|/Volumes|/tmp)/[^\s，；]+"#,
            #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#,
            #"(?i)\b(?:password|passwd|token|secret|authorization|proxy)[=:][^\s，；]+"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[已隐藏]", options: .regularExpression)
        }
        return result
    }
}

extension Exchange {
    var diagnosticCatalogueHostnames: [String] {
        switch self {
        case .okx: return ["openapi.okx.com"]
        case .binance: return ["api.binance.com", "fapi.binance.com", "dapi.binance.com"]
        case .bybit: return ["api.bybit.com"]
        }
    }

    func diagnosticQuoteHostname(for market: MarketKind) -> String {
        switch self {
        case .okx: return "openapi.okx.com"
        case .binance:
            switch market {
            case .spot: return "api.binance.com"
            case .linearPerpetual: return "fapi.binance.com"
            case .inversePerpetual: return "dapi.binance.com"
            }
        case .bybit: return "api.bybit.com"
        }
    }
}
