import Foundation
import XCTest
@testable import MarkBarCore

final class ReleaseUpdateTests: XCTestCase {
    func testSemanticVersionsAreStrictAndComparable() {
        XCTAssertEqual(AppVersion("v0.2.0"), AppVersion(major: 0, minor: 2, patch: 0))
        XCTAssertEqual(AppVersion("1.10.0")?.description, "1.10.0")
        XCTAssertTrue(AppVersion("0.10.0")! > AppVersion("0.2.9")!)
        XCTAssertNil(AppVersion("1.2"))
        XCTAssertNil(AppVersion("1.2.3-beta"))
        XCTAssertNil(AppVersion("01.2.3"))
        XCTAssertNil(AppVersion("1.2.3.4"))
    }

    func testGitHubReleaseParserAcceptsOnlyStableReleaseForOfficialRepository() throws {
        let valid = Data(#"""
        {
          "tag_name":"v0.2.0","name":"TideTicker 0.2.0","draft":false,"prerelease":false,
          "html_url":"https://github.com/realRongCat/TideTicker/releases/tag/v0.2.0",
          "published_at":"2026-10-26T01:02:03Z"
        }
        """#.utf8)
        let release = try GitHubReleaseClient.parseRelease(valid)
        XCTAssertEqual(release?.version, AppVersion("0.2.0"))
        XCTAssertEqual(release?.title, "TideTicker 0.2.0")

        let prerelease = Data(#"""
        {
          "tag_name":"v0.2.0","name":"Beta","draft":false,"prerelease":true,
          "html_url":"https://github.com/realRongCat/TideTicker/releases/tag/v0.2.0",
          "published_at":"2026-10-26T01:02:03Z"
        }
        """#.utf8)
        XCTAssertNil(try GitHubReleaseClient.parseRelease(prerelease))

        let wrongRepository = Data(#"""
        {
          "tag_name":"v0.2.0","name":"Other","draft":false,"prerelease":false,
          "html_url":"https://github.com/someone/TideTicker/releases/tag/v0.2.0",
          "published_at":"2026-10-26T01:02:03Z"
        }
        """#.utf8)
        XCTAssertThrowsError(try GitHubReleaseClient.parseRelease(wrongRepository))
    }

    func testAutomaticCheckPromptsOnceThenKeepsUpdateAvailable() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let release = makeRelease("0.2.0", date: now)
        let fetcher = StubReleaseFetcher([.success(.release(release, etag: "etag-1"))])
        let store = MemoryReleaseUpdateStore()
        let monitor = ReleaseUpdateMonitor(currentVersion: AppVersion("0.1.0")!, fetcher: fetcher,
                                           store: store, now: { now })

        let firstOutcome = await monitor.check(.automatic)
        XCTAssertEqual(firstOutcome, .available(release, shouldPresent: true))
        await monitor.record(.presented, for: release)
        let cachedOutcome = await monitor.cachedOutcome()
        XCTAssertEqual(cachedOutcome, .available(release, shouldPresent: false))
        let state = await store.snapshot()
        XCTAssertEqual(state.etag, "etag-1")
        XCTAssertEqual(state.lastPromptedVersion, release.version)
    }

    func testSnoozeAndSkipOnlySuppressAutomaticPresentation() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let release = makeRelease("0.2.0", date: now)
        let store = MemoryReleaseUpdateStore(initial: .init(cachedRelease: release))
        let fetcher = StubReleaseFetcher([])
        let monitor = ReleaseUpdateMonitor(currentVersion: AppVersion("0.1.0")!, fetcher: fetcher,
                                           store: store, now: { now })

        let later = now.addingTimeInterval(86_400)
        await monitor.record(.remindLater(until: later), for: release)
        let deferredOutcome = await monitor.cachedOutcome()
        XCTAssertEqual(deferredOutcome, .deferred(release, until: later))
        let manualOutcome = await monitor.check(.manual)
        XCTAssertEqual(manualOutcome, .failed(message: StubError.empty.localizedDescription,
                                               retryAt: now.addingTimeInterval(1_800)))

        await monitor.record(.skip, for: release)
        let skippedOutcome = await monitor.cachedOutcome()
        XCTAssertEqual(skippedOutcome, .skipped(release))
    }

    func testNewerReleaseIsNotSuppressedBySkippedOlderVersion() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = makeRelease("0.2.0", date: now)
        let newer = makeRelease("0.2.1", date: now.addingTimeInterval(60))
        let store = MemoryReleaseUpdateStore(initial: .init(cachedRelease: old, skippedVersion: old.version))
        let fetcher = StubReleaseFetcher([.success(.release(newer, etag: "etag-2"))])
        let monitor = ReleaseUpdateMonitor(currentVersion: AppVersion("0.1.0")!, fetcher: fetcher,
                                           store: store, regularInterval: 0, now: { now })

        let outcome = await monitor.check(.automatic)
        XCTAssertEqual(outcome, .available(newer, shouldPresent: true))
    }

    func testConditionalResponseKeepsCachedReleaseAndAdvancesSuccessfulCheck() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let release = makeRelease("0.2.0", date: now)
        let store = MemoryReleaseUpdateStore(initial: .init(etag: "etag-1", cachedRelease: release))
        let fetcher = StubReleaseFetcher([.success(.notModified(etag: "etag-1"))])
        let monitor = ReleaseUpdateMonitor(currentVersion: AppVersion("0.1.0")!, fetcher: fetcher,
                                           store: store, regularInterval: 0, now: { now })

        let outcome = await monitor.check(.automatic)
        let receivedETags = await fetcher.receivedETags()
        let storedState = await store.snapshot()
        XCTAssertEqual(outcome, .available(release, shouldPresent: true))
        XCTAssertEqual(receivedETags, ["etag-1"])
        XCTAssertEqual(storedState.lastSuccessfulCheckAt, now)
    }

    private func makeRelease(_ version: String, date: Date) -> AppRelease {
        AppRelease(version: AppVersion(version)!, tagName: "v\(version)", title: "TideTicker \(version)",
                   publishedAt: date,
                   releaseURL: URL(string: "https://github.com/realRongCat/TideTicker/releases/tag/v\(version)")!)
    }
}

private enum StubError: LocalizedError, Sendable {
    case empty
    var errorDescription: String? { "没有预设响应" }
}

private actor StubReleaseFetcher: ReleaseUpdateFetching {
    private var responses: [Result<ReleaseUpdateFetchResult, StubError>]
    private var etags: [String?] = []

    init(_ responses: [Result<ReleaseUpdateFetchResult, StubError>]) {
        self.responses = responses
    }

    func latestRelease(ifNoneMatch etag: String?) async throws -> ReleaseUpdateFetchResult {
        etags.append(etag)
        guard !responses.isEmpty else { throw StubError.empty }
        return try responses.removeFirst().get()
    }

    func receivedETags() -> [String?] { etags }
}

private actor MemoryReleaseUpdateStore: ReleaseUpdateStateStoring {
    private var state: ReleaseUpdateState

    init(initial: ReleaseUpdateState = .init()) { state = initial }

    func load() async -> ReleaseUpdateState { state }
    func save(_ state: ReleaseUpdateState) async { self.state = state }
    func snapshot() -> ReleaseUpdateState { state }
}
