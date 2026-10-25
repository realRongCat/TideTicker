import AppKit
import Combine
import Darwin
import Foundation
import MarkBarCore

enum TideKindleServiceState: Equatable {
    case disabled
    case starting
    case ready
    case awaitingAddress
    case failed
    case stopped
}

@MainActor
final class TideKindleModel: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var refreshInterval: TimeInterval
    @Published private(set) var status = "未启用"
    @Published private(set) var serviceState: TideKindleServiceState = .disabled
    @Published private(set) var address = ""
    @Published private(set) var lastPublishedAt: Date?

    var onSetEnabled: ((Bool) -> Void)?
    var onSetRefreshInterval: ((TimeInterval) -> Void)?
    var onResetToken: (() -> Void)?

    init(enabled: Bool, refreshInterval: TimeInterval) {
        self.enabled = enabled
        self.refreshInterval = refreshInterval
    }

    func setEnabled(_ enabled: Bool) { onSetEnabled?(enabled) }
    func setRefreshInterval(_ interval: TimeInterval) { onSetRefreshInterval?(interval) }
    func resetToken() { onResetToken?() }

    fileprivate func update(enabled: Bool? = nil, refreshInterval: TimeInterval? = nil,
                            status: String? = nil, serviceState: TideKindleServiceState? = nil,
                            address: String? = nil,
                            lastPublishedAt: Date? = nil) {
        if let enabled { self.enabled = enabled }
        if let refreshInterval { self.refreshInterval = refreshInterval }
        if let status { self.status = status }
        if let serviceState { self.serviceState = serviceState }
        if let address { self.address = address }
        if let lastPublishedAt { self.lastPublishedAt = lastPublishedAt }
    }
}

@MainActor
final class TideKindleController {
    private static let enabledKey = "tide.kindle.enabled"
    private static let refreshIntervalKey = "tide.kindle.refreshInterval"
    private static let tokenKey = "tide.kindle.token"
    private static let port: UInt16 = 8765

    let model: TideKindleModel
    private let defaults: UserDefaults
    private var server = KindleHTTPServer()
    private var token: String
    private var latestSnapshot: KindleDisplaySnapshot?
    private var lastPublishedAt = Date.distantPast
    private var lastCriticalSignature = ""
    private var generation: UInt64 = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedInterval = defaults.double(forKey: Self.refreshIntervalKey)
        let interval = [5.0, 10, 15, 30].contains(savedInterval) ? savedInterval : 10
        let savedToken = defaults.string(forKey: Self.tokenKey)
        token = savedToken?.isEmpty == false ? savedToken! : Self.makeToken()
        defaults.set(token, forKey: Self.tokenKey)
        defaults.set(interval, forKey: Self.refreshIntervalKey)
        model = TideKindleModel(enabled: defaults.bool(forKey: Self.enabledKey),
                                refreshInterval: interval)
    }

    func configureCallbacks() {
        model.onSetEnabled = { [weak self] in self?.setEnabled($0) }
        model.onSetRefreshInterval = { [weak self] in self?.setRefreshInterval($0) }
        model.onResetToken = { [weak self] in self?.resetToken() }
    }

    func startIfEnabled() {
        guard model.enabled else { return }
        start()
    }

    func publish(_ snapshot: KindleDisplaySnapshot, force: Bool = false) {
        latestSnapshot = snapshot
        guard model.enabled else { return }
        let criticalChanged = snapshot.criticalSignature != lastCriticalSignature
        let due = snapshot.generatedAt.timeIntervalSince(lastPublishedAt) >= model.refreshInterval
        guard force || criticalChanged || due else { return }
        do {
            let data = try Self.encoder.encode(snapshot)
            server.update(snapshot: data)
            lastPublishedAt = snapshot.generatedAt
            lastCriticalSignature = snapshot.criticalSignature
            model.update(lastPublishedAt: snapshot.generatedAt)
            refreshAddress()
        } catch {
            model.update(status: "生成展示快照失败：\(error.localizedDescription)", serviceState: .failed)
        }
    }

    func stop() {
        generation &+= 1
        server.stop()
        model.update(status: "未启用", serviceState: .disabled, address: "")
    }

    private func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        model.update(enabled: enabled)
        if enabled { start() } else { stop() }
    }

    private func setRefreshInterval(_ interval: TimeInterval) {
        let normalized = [5.0, 10, 15, 30].contains(interval) ? interval : 10
        defaults.set(normalized, forKey: Self.refreshIntervalKey)
        model.update(refreshInterval: normalized)
        if let latestSnapshot { publish(latestSnapshot, force: true) }
    }

    private func resetToken() {
        token = Self.makeToken()
        defaults.set(token, forKey: Self.tokenKey)
        guard model.enabled else { return }
        server.stop()
        server = KindleHTTPServer()
        start()
    }

    private func start() {
        generation &+= 1
        let expectedGeneration = generation
        guard let html = Self.loadIndexHTML() else {
            model.update(status: "缺少 Kindle 页面资源", serviceState: .failed, address: "")
            return
        }
        do {
            try server.start(port: Self.port, token: token, indexHTML: html) { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == expectedGeneration else { return }
                    switch state {
                    case .starting:
                        self.model.update(status: "正在启动…", serviceState: .starting, address: "")
                    case .ready:
                        self.model.update(status: "局域网只读展示已开启", serviceState: .ready)
                        self.refreshAddress()
                        if let latestSnapshot = self.latestSnapshot {
                            self.publish(latestSnapshot, force: true)
                        }
                    case .failed(let message):
                        self.model.update(status: "启动失败：\(message)", serviceState: .failed, address: "")
                    case .stopped:
                        if self.model.enabled {
                            self.model.update(status: "服务已停止", serviceState: .stopped, address: "")
                        }
                    }
                }
            }
        } catch {
            model.update(status: "启动失败：\(error.localizedDescription)", serviceState: .failed, address: "")
        }
    }

    private func refreshAddress() {
        guard model.enabled,
              model.serviceState == .ready || model.serviceState == .awaitingAddress else { return }
        guard let address = Self.localIPv4Address() else {
            model.update(status: "已启动，但尚未找到局域网 IPv4 地址",
                         serviceState: .awaitingAddress, address: "")
            return
        }
        model.update(status: "局域网只读展示已开启", serviceState: .ready,
                     address: "http://\(address):\(Self.port)/k/\(token)/")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static func makeToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func loadIndexHTML() -> Data? {
        if let bundled = Bundle.main.url(forResource: "index", withExtension: "html",
                                         subdirectory: "Kindle") {
            return try? Data(contentsOf: bundled)
        }
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        for parent in candidates {
            let bundleURL = parent.appendingPathComponent("TideTicker_MarkBarApp.bundle")
            if let bundle = Bundle(url: bundleURL),
               let bundled = bundle.url(forResource: "index", withExtension: "html",
                                         subdirectory: "Kindle") {
                return try? Data(contentsOf: bundled)
            }
        }
        return nil
    }

    private static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var candidates: [(priority: Int, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                                     socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let value = String(decoding: bytes, as: UTF8.self)
            guard !value.hasPrefix("169.254.") else { continue }
            let priority = name == "en0" ? 0 : (name == "en1" ? 1 : 2)
            candidates.append((priority, value))
        }
        return candidates.sorted { $0.priority < $1.priority }.first?.address
    }
}
