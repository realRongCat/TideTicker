import Foundation

public enum NetworkMode: String, Codable, CaseIterable, Sendable {
    case system
    case physicalDirect

    public var title: String {
        switch self {
        case .system: return "系统网络"
        case .physicalDirect: return "物理直连"
        }
    }

    public var detail: String {
        switch self {
        case .system: return "遵循 macOS 当前网络与代理设置"
        case .physicalDirect: return "绑定物理网卡并独立解析域名，跳过系统代理"
        }
    }
}
