import AppKit
import Foundation
import MarkBarCore

enum TideUpdateMenuState: Equatable {
    case idle
    case checking
    case available(AppRelease)
}

private final class TideUpdateDefaults: @unchecked Sendable {
    let value: UserDefaults
    init(_ value: UserDefaults) { self.value = value }
}

private actor TideUpdateStateStore: ReleaseUpdateStateStoring {
    private let defaults: TideUpdateDefaults
    private let key: String

    init(defaults: TideUpdateDefaults, key: String = "tide.updateState.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() async -> ReleaseUpdateState {
        guard let data = defaults.value.data(forKey: key),
              let state = try? JSONDecoder().decode(ReleaseUpdateState.self, from: data) else { return .init() }
        return state
    }

    func save(_ state: ReleaseUpdateState) async {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.value.set(data, forKey: key)
    }
}

actor TideVolatileUpdateStateStore: ReleaseUpdateStateStoring {
    private var state = ReleaseUpdateState()
    func load() async -> ReleaseUpdateState { state }
    func save(_ state: ReleaseUpdateState) async { self.state = state }
}

actor TideStaticReleaseFetcher: ReleaseUpdateFetching {
    let release: AppRelease
    init(release: AppRelease) { self.release = release }
    func latestRelease(ifNoneMatch etag: String?) async throws -> ReleaseUpdateFetchResult {
        .release(release, etag: "fixture-\(release.version)")
    }
}

@MainActor
final class TideUpdateController {
    static let automaticChecksKey = "tide.automaticUpdateChecks.v1"
    let currentVersion: AppVersion
    var onMenuStateChange: ((TideUpdateMenuState) -> Void)?
    var onAutomaticChecksChange: ((Bool) -> Void)?

    private let defaults: UserDefaults
    private let monitor: ReleaseUpdateMonitor
    private let panel = TideUpdatePanelController()
    private let anchor: () -> NSStatusItem?
    private let automaticChecksAllowed: Bool
    private var scheduleTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var completedStartupDelay = false
    private(set) var menuState: TideUpdateMenuState = .idle

    var isPanelVisible: Bool { panel.window?.isVisible == true }

    var automaticallyChecks: Bool {
        guard automaticChecksAllowed else { return false }
        return defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    }

    init(currentVersion: AppVersion, fetcher: any ReleaseUpdateFetching,
         defaults: UserDefaults, automaticChecksAllowed: Bool,
         stateStore: (any ReleaseUpdateStateStoring)? = nil,
         anchor: @escaping () -> NSStatusItem?) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.automaticChecksAllowed = automaticChecksAllowed
        self.anchor = anchor
        let store = stateStore ?? TideUpdateStateStore(defaults: TideUpdateDefaults(defaults))
        monitor = ReleaseUpdateMonitor(currentVersion: currentVersion, fetcher: fetcher, store: store)
    }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.monitor.cachedOutcome()
            self.receive(outcome, trigger: .automatic)
        }
        restartSchedule()
    }

    func checkIfDue() {
        guard automaticallyChecks, completedStartupDelay else { return }
        performCheck(.automatic)
    }

    func checkNow() {
        if checkTask != nil {
            panel.presentMessage(title: "正在检查更新", detail: "请稍候。", symbol: "arrow.triangle.2.circlepath",
                                 anchor: anchor(), dismissAfter: 3)
            return
        }
        performCheck(.manual)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        guard automaticChecksAllowed else { return }
        defaults.set(enabled, forKey: Self.automaticChecksKey)
        onAutomaticChecksChange?(enabled)
        restartSchedule()
        if enabled { checkIfDue() }
    }

    func presentAvailableUpdate() {
        guard case let .available(release) = menuState else { return }
        present(release)
    }

    func stop() {
        scheduleTask?.cancel(); scheduleTask = nil
        checkTask?.cancel(); checkTask = nil
        panel.dismiss()
    }

    private func restartSchedule() {
        scheduleTask?.cancel(); scheduleTask = nil
        guard automaticallyChecks else { return }
        scheduleTask = Task { [weak self] in
            let initialDelay = UInt64(Double.random(in: 20...60) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: initialDelay)
            guard !Task.isCancelled else { return }
            self?.completedStartupDelay = true
            while !Task.isCancelled {
                self?.checkIfDue()
                let interval = Double.random(in: (30 * 60)...(40 * 60))
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func performCheck(_ trigger: UpdateCheckTrigger) {
        guard checkTask == nil else { return }
        setMenuState(.checking)
        let monitor = monitor
        checkTask = Task { [weak self] in
            let outcome = await monitor.check(trigger)
            guard !Task.isCancelled else { return }
            self?.checkTask = nil
            self?.receive(outcome, trigger: trigger)
        }
    }

    private func receive(_ outcome: ReleaseUpdateOutcome, trigger: UpdateCheckTrigger) {
        switch outcome {
        case .current:
            setMenuState(.idle)
            if trigger == .manual {
                panel.presentMessage(title: "已是最新版本", detail: "当前版本为 TideTicker \(currentVersion)。",
                                     symbol: "checkmark.circle", anchor: anchor())
            }
        case let .available(release, shouldPresent):
            setMenuState(.available(release))
            if trigger == .manual || shouldPresent { present(release) }
        case let .deferred(release, _):
            setMenuState(.available(release))
        case .skipped:
            setMenuState(.idle)
        case let .failed(message, _):
            setMenuState(.idle)
            if trigger == .manual {
                panel.presentMessage(title: "无法检查更新", detail: message,
                                     symbol: "exclamationmark.triangle", anchor: anchor(), dismissAfter: 8)
            }
        }
    }

    private func present(_ release: AppRelease) {
        Task { await monitor.record(.presented, for: release) }
        panel.presentRelease(release, currentVersion: currentVersion, anchor: anchor(), onOpen: { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(release.releaseURL)
            self.remindLater(release)
        }, onRemindLater: { [weak self] in
            self?.remindLater(release)
        }, onSkip: { [weak self] in
            guard let self else { return }
            self.panel.dismiss()
            self.setMenuState(.idle)
            Task { await self.monitor.record(.skip, for: release) }
        })
    }

    private func remindLater(_ release: AppRelease) {
        panel.dismiss()
        setMenuState(.available(release))
        let until = Date().addingTimeInterval(24 * 60 * 60)
        Task { await monitor.record(.remindLater(until: until), for: release) }
    }

    private func setMenuState(_ state: TideUpdateMenuState) {
        guard menuState != state else { return }
        menuState = state
        onMenuStateChange?(state)
    }
}
