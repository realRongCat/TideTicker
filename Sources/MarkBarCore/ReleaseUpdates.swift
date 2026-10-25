import Foundation

public struct AppVersion: Codable, Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = trimmed.first == "v" || trimmed.first == "V" ? String(trimmed.dropFirst()) : trimmed
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Self.parseComponent(parts[0]),
              let minor = Self.parseComponent(parts[1]),
              let patch = Self.parseComponent(parts[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    private static func parseComponent(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber),
              value.count == 1 || value.first != "0" else { return nil }
        return Int(value)
    }
}

public struct AppRelease: Codable, Equatable, Sendable {
    public let version: AppVersion
    public let tagName: String
    public let title: String
    public let publishedAt: Date
    public let releaseURL: URL

    public init(version: AppVersion, tagName: String, title: String,
                publishedAt: Date, releaseURL: URL) {
        self.version = version
        self.tagName = tagName
        self.title = title
        self.publishedAt = publishedAt
        self.releaseURL = releaseURL
    }
}

public enum ReleaseUpdateFetchResult: Sendable, Equatable {
    case release(AppRelease, etag: String?)
    case notModified(etag: String?)
    case noRelease(etag: String?)
}

public protocol ReleaseUpdateFetching: Sendable {
    func latestRelease(ifNoneMatch etag: String?) async throws -> ReleaseUpdateFetchResult
}

public struct ReleaseUpdateState: Codable, Equatable, Sendable {
    public var lastAttemptAt: Date?
    public var lastSuccessfulCheckAt: Date?
    public var etag: String?
    public var cachedRelease: AppRelease?
    public var snoozedVersion: AppVersion?
    public var snoozedUntil: Date?
    public var skippedVersion: AppVersion?
    public var lastPromptedVersion: AppVersion?
    public var lastPromptedAt: Date?
    public var consecutiveFailures: Int
    public var retryAfter: Date?

    public init(lastAttemptAt: Date? = nil, lastSuccessfulCheckAt: Date? = nil,
                etag: String? = nil, cachedRelease: AppRelease? = nil,
                snoozedVersion: AppVersion? = nil, snoozedUntil: Date? = nil,
                skippedVersion: AppVersion? = nil, lastPromptedVersion: AppVersion? = nil,
                lastPromptedAt: Date? = nil, consecutiveFailures: Int = 0,
                retryAfter: Date? = nil) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.etag = etag
        self.cachedRelease = cachedRelease
        self.snoozedVersion = snoozedVersion
        self.snoozedUntil = snoozedUntil
        self.skippedVersion = skippedVersion
        self.lastPromptedVersion = lastPromptedVersion
        self.lastPromptedAt = lastPromptedAt
        self.consecutiveFailures = consecutiveFailures
        self.retryAfter = retryAfter
    }
}

public protocol ReleaseUpdateStateStoring: Sendable {
    func load() async -> ReleaseUpdateState
    func save(_ state: ReleaseUpdateState) async
}

public enum UpdateCheckTrigger: Sendable {
    case automatic
    case manual
}

public enum ReleaseUpdateOutcome: Equatable, Sendable {
    case current(checkedAt: Date?)
    case available(AppRelease, shouldPresent: Bool)
    case skipped(AppRelease)
    case deferred(AppRelease, until: Date)
    case failed(message: String, retryAt: Date?)
}

public enum ReleaseUpdateAction: Sendable {
    case presented
    case remindLater(until: Date)
    case skip
    case clearSkip
}

public protocol ReleaseUpdateRetryProviding: Error {
    var retryAt: Date? { get }
}

public actor ReleaseUpdateMonitor {
    private let currentVersion: AppVersion
    private let fetcher: any ReleaseUpdateFetching
    private let store: any ReleaseUpdateStateStoring
    private let regularInterval: TimeInterval
    private let promptInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var loadedState: ReleaseUpdateState?

    public init(currentVersion: AppVersion, fetcher: any ReleaseUpdateFetching,
                store: any ReleaseUpdateStateStoring,
                regularInterval: TimeInterval = 4 * 60 * 60,
                promptInterval: TimeInterval = 24 * 60 * 60,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.currentVersion = currentVersion
        self.fetcher = fetcher
        self.store = store
        self.regularInterval = regularInterval
        self.promptInterval = promptInterval
        self.now = now
    }

    public func cachedOutcome() async -> ReleaseUpdateOutcome {
        let state = await state()
        return evaluate(state, trigger: .automatic, at: now())
    }

    public func check(_ trigger: UpdateCheckTrigger) async -> ReleaseUpdateOutcome {
        var state = await state()
        let checkedAt = now()
        if trigger == .automatic, !isDue(state, at: checkedAt) {
            return evaluate(state, trigger: trigger, at: checkedAt)
        }

        do {
            let result = try await fetcher.latestRelease(ifNoneMatch: state.etag)
            state.lastAttemptAt = checkedAt
            state.lastSuccessfulCheckAt = checkedAt
            state.consecutiveFailures = 0
            state.retryAfter = nil
            switch result {
            case let .release(release, etag):
                state.cachedRelease = release
                state.etag = etag
                if state.snoozedVersion != release.version {
                    state.snoozedVersion = nil
                    state.snoozedUntil = nil
                }
            case let .notModified(etag):
                if let etag { state.etag = etag }
            case let .noRelease(etag):
                state.cachedRelease = nil
                state.etag = etag
            }
            await persist(state)
            return evaluate(state, trigger: trigger, at: checkedAt)
        } catch {
            state.lastAttemptAt = checkedAt
            state.consecutiveFailures = min(state.consecutiveFailures + 1, 20)
            let suppliedRetry = (error as? any ReleaseUpdateRetryProviding)?.retryAt
            state.retryAfter = suppliedRetry ?? checkedAt.addingTimeInterval(Self.backoff(for: state.consecutiveFailures))
            await persist(state)
            if case .available = evaluate(state, trigger: .automatic, at: checkedAt) {
                return evaluate(state, trigger: .automatic, at: checkedAt)
            }
            return .failed(message: error.localizedDescription, retryAt: state.retryAfter)
        }
    }

    public func record(_ action: ReleaseUpdateAction, for release: AppRelease) async {
        var state = await state()
        switch action {
        case .presented:
            state.lastPromptedVersion = release.version
            state.lastPromptedAt = now()
        case let .remindLater(until):
            state.snoozedVersion = release.version
            state.snoozedUntil = until
            state.lastPromptedVersion = release.version
            state.lastPromptedAt = now()
        case .skip:
            state.skippedVersion = release.version
            state.snoozedVersion = nil
            state.snoozedUntil = nil
        case .clearSkip:
            if state.skippedVersion == release.version { state.skippedVersion = nil }
        }
        await persist(state)
    }

    private func state() async -> ReleaseUpdateState {
        if let loadedState { return loadedState }
        let stored = await store.load()
        loadedState = stored
        return stored
    }

    private func persist(_ state: ReleaseUpdateState) async {
        loadedState = state
        await store.save(state)
    }

    private func isDue(_ state: ReleaseUpdateState, at date: Date) -> Bool {
        if let retryAfter = state.retryAfter, retryAfter > date { return false }
        guard let lastAttemptAt = state.lastAttemptAt else { return true }
        let interval = state.consecutiveFailures == 0
            ? regularInterval
            : Self.backoff(for: state.consecutiveFailures)
        return date.timeIntervalSince(lastAttemptAt) >= interval
    }

    private func evaluate(_ state: ReleaseUpdateState, trigger: UpdateCheckTrigger,
                          at date: Date) -> ReleaseUpdateOutcome {
        guard let release = state.cachedRelease, release.version > currentVersion else {
            return .current(checkedAt: state.lastSuccessfulCheckAt)
        }
        if trigger == .manual { return .available(release, shouldPresent: true) }
        if state.skippedVersion == release.version { return .skipped(release) }
        if state.snoozedVersion == release.version,
           let snoozedUntil = state.snoozedUntil, snoozedUntil > date {
            return .deferred(release, until: snoozedUntil)
        }
        let recentlyPrompted = state.lastPromptedVersion == release.version
            && state.lastPromptedAt.map { date.timeIntervalSince($0) < promptInterval } == true
        return .available(release, shouldPresent: !recentlyPrompted)
    }

    private static func backoff(for failures: Int) -> TimeInterval {
        switch failures {
        case ..<2: return 30 * 60
        case 2: return 60 * 60
        default: return 4 * 60 * 60
        }
    }
}
